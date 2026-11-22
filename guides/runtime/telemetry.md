# Telemetry

OzMcp emits its events with the package
[`:telemetry`](https://hexdocs.pm/telemetry). A handler of the host
application counts the refusals, measures the time of a request and
watches the life of sessions and tasks. The log keeps every message it
had: the events add numbers to the log, they remove no line of it.

## The prefix of the events

Each event name starts with a prefix. The default prefix is `[:oz_mcp]`,
so the name of an event is for example `[:oz_mcp, :request, :stop]`.

The option `telemetry_prefix` changes the prefix of one instance:

```elixir
children = [
  {OzMcp, server: MyApp.EngineeringServer, telemetry_prefix: [:oz_mcp, :engineering]}
]
```

The value must be a non-empty list of atoms. Another value stops the
boot with an `ArgumentError`. OzMcp reads the prefix one time at boot
and builds each full event name from it.

## Many instances in one application

Many instances of the framework run side by side in one application.
Each event carries the name of its instance and its server module in
the metadata, so one handler can tell the events of the instances
apart. Two instances can share one prefix and an application can also
give each instance a prefix of its own:

```elixir
children = [
  {OzMcp,
   server: MyApp.EngineeringServer, telemetry_prefix: [:oz_mcp, :engineering]},
  {OzMcp,
   server: MyApp.MarketingServer, telemetry_prefix: [:oz_mcp, :marketing]}
]

# One handler for one instance:
:telemetry.attach(
  "engineering-requests",
  [:oz_mcp, :engineering, :request, :stop],
  &MyApp.Metrics.handle_event/4,
  nil
)

# One handler for all the instances (the default prefix),
# with the instance as a tag:
Telemetry.Metrics.summary("oz_mcp.request.stop.duration",
  unit: {:native, :millisecond},
  tags: [:instance, :method]
)
```

## The metadata of the events

Each event carries the same two keys in its metadata:

| Key | Value |
|---|---|
| `instance` | the name of the instance (the server module by default) |
| `server` | the server module |

A span is a pair of events `:start` and `:stop` (and in the rare case
of a defect of the library, an event `:exception`). The events of a
span carry the key `telemetry_span_context` and its value is the same
reference at the start and at the end. A handler correlates the two
events with it.

The metadata holds only atoms, integers, booleans and names that the
server declared. It holds no session id, no task id, no token, no
parameter and no result of a request.

## The events

The table lists the events of the library. It grows with the library:

| Event | Measurements | Other metadata |
|---|---|---|
| `[:oz_mcp, :request, :start]` | `system_time`, `monotonic_time` | `transport`, `method`, `kind` |
| `[:oz_mcp, :request, :stop]` | `duration` | `transport`, `method`, `kind`, `result`, `status`, `error_code` |
| `[:oz_mcp, :request, :exception]` | `duration` | `transport`, `method`, `kind`, `exception_kind`, `reason`, `stacktrace` |
| `[:oz_mcp, :callback, :start]` | `system_time`, `monotonic_time` | `method`, `name` |
| `[:oz_mcp, :callback, :stop]` | `duration` | `method`, `name`, `result`, `error_code` |
| `[:oz_mcp, :callback, :exception]` | `duration` | `method`, `name`, `exception_kind`, `reason`, `stacktrace` |
| `[:oz_mcp, :session, :start]` | `system_time`, `monotonic_time` | `transport`, `restored?` |
| `[:oz_mcp, :session, :stop]` | `duration` | `transport`, `restored?`, `reason` |
| `[:oz_mcp, :task, :start]` | `system_time`, `monotonic_time` | |
| `[:oz_mcp, :task, :stop]` | `duration` | `status` |
| `[:oz_mcp, :client_request, :start]` | `system_time`, `monotonic_time` | `method` |
| `[:oz_mcp, :client_request, :stop]` | `duration` | `method`, `result` |
| `[:oz_mcp, :client_request, :exception]` | `duration` | `method`, `exception_kind`, `reason`, `stacktrace` |
| `[:oz_mcp, :client_task, :start]` | `system_time`, `monotonic_time` | `method` |
| `[:oz_mcp, :client_task, :stop]` | `duration` | `method`, `result` |
| `[:oz_mcp, :client_task, :exception]` | `duration` | `method`, `exception_kind`, `reason`, `stacktrace` |
| `[:oz_mcp, :auth, :refused]` | `count` | `stage`, `reason` |
| `[:oz_mcp, :limit, :reached]` | `count` | `limit`, `limit_value`, `scope`, `outcome` |
| `[:oz_mcp, :session, :restore]` | `count` | `outcome` |
| `[:oz_mcp, :snapshot, :write]` | `duration` | `action`, `result` |
| `[:oz_mcp, :principal, :revoked]` | `sessions` | |
| `[:oz_mcp, :subscription, :dropped]` | `count` | `reason` |
| `[:oz_mcp, :log, :dropped]` | `count` | |

## The request span

Each JSON-RPC message that a transport accepts gives one `request`
span: a `:start` before the validation of the message and a `:stop`
after the answer went out (or an `:exception`, when the library itself
fails; the reason and the stacktrace name the defect). The `duration`
of the `:stop` is in native time units. A handler correlates the
`:start` and the `:stop` with `telemetry_span_context`.

The metadata of the span:

| Key | Values |
|---|---|
| `transport` | `:http_streamable` or `:stdio` |
| `method` | a method that the server serves (for example `"ping"`), `:unknown` for a method that it does not serve (the text of the client never goes out), or `nil` when the message has no method (an answer of the client, a body that is not a JSON-RPC message) |
| `kind` | `:request`, `:notification`, `:response` or `:invalid` (a method with an id that is not a string or an integer is `:invalid`) |
| `result` (on `:stop`) | `:ok` when the handler answered a success or took a notification or an answer of the client, `:rpc_error` when the handler answered a JSON-RPC error, or `:error` when the transport or the pipeline refused the message |
| `status` (on `:stop`) | the HTTP status on the Streamable HTTP transport, `nil` on stdio |
| `error_code` (on `:stop`) | the code atom of a refusal of the transport or of the pipeline (for example `:http_no_accept_header`), or `nil` |

The span covers a message of a `POST` on HTTP and each decoded line on
stdio. A request that the HTTP router refuses before the `POST` route
has no span: an instance that does not run (`503`), a refused `Host` or
`Origin` (`403`), a refused credential (`401`, `403`) and a body that
no parser accepts (`415`, `400`). A refusal of the authentication gives
the `auth` event instead. A `GET` and a `DELETE` have no `request`
span: they carry no JSON-RPC message.

A `POST` stream that closes for real (at the expiry of the principal or
at `sse_max_stream_ms`) gives a `request` span with `result: :ok` and
the status `200`: the connection ends before the callback answers. The
outcome of the callback is in its `callback` span.

On stdio, the span of one request starts in the process of the
transport and ends in the process of the request when the method is not
a cheap one. A request whose process an exit signal stops (the end of
the drain time) emits a `:start` with no `:stop`.

## The callback span

Each synchronous callback of a user entity gives one `callback` span:
the `call/2` of a tool, the `read/2` of a resource, the `read/4` of a
resource template, the `get/2` of a prompt and the `complete/4` of a
completion. The span covers the run of the callback and the wait of the
caller. A request that the validation refuses before the entity runs
(an unknown name, arguments that violate the schema, a missing
capability) runs no callback and gives no span.

The metadata of the span:

| Key | Values |
|---|---|
| `method` | `"tools/call"`, `"resources/read"`, `"prompts/get"` or `"completion/complete"` |
| `name` | the name that the server declared for the entity (the tool, the prompt, the resource or the template), or `nil` for a completion. The uri of a resource and the arguments of the request never go out |
| `result` (on `:stop`) | `:ok`, `:error` (the callback answered an error of its own), `:cancelled`, `:timeout` (the deadline stopped the callback), `:crashed` (a crash, a bad result shape or a refused error) or `:session_terminated` |
| `error_code` (on `:stop`) | the code of the JSON-RPC error of the outcome, `nil` for `:ok` |

The crash guard of the framework turns every failure of a callback
into an error result, so the `:stop` event carries the outcome. The
`:exception` event is rare: it names a defect of the framework itself.

Two callbacks have no `callback` span: the callback of a task (the span
of the task covers it) and the callback of
`roots_list_changed/1` (the session owns its deadline).

## The session span

Each session gives one `session` span: a `:start` when the process of
the session starts (a new session, or a session that a snapshot of the
store restored) and a `:stop` when the process ends. The `:start`
comes after the session is in the registry, so a handler that reads the
sessions of the instance on this event finds the new one.

The metadata of the span:

| Key | Values |
|---|---|
| `transport` | `:http_streamable` or `:stdio` |
| `restored?` | `true` when the session started from a snapshot, `false` for a new session |
| `reason` (on `:stop`) | the reason of the end, in the list below |

The values of `reason`:

| Value | The end that gave it |
|---|---|
| `:terminated` | a `DELETE` of the client, the end of the stdio transport, or the end of every session of a principal |
| `:evicted` | the server ended the session to make room for a new one, see `max_sessions` |
| `:idle` | the idle timer of the session ran out |
| `:init_timeout` | the session never sent `notifications/initialized` in time |
| `:closed` | another end that the session itself decided |
| `:normal` | the process ended with no error and no end of its own |
| `:crash` | a failure inside the session process |

One end emits no `:stop`: an exit signal (the end of the instance, a
`Process.exit/2` from the host, a kill) stops the process without the
final step that emits the event. Such a session gives a `:start` with
no `:stop`.

## The task span

Each task gives one `task` span: a `:start` when the process of the
task starts and a `:stop` when it ends. The `:stop` carries the final
status of the task in the key `status`:

| Value | The end that gave it |
|---|---|
| `:completed` | the tool answered and the task stored its result |
| `:failed` | the tool reported an error or crashed, or the process of the task crashed or was killed |
| `:cancelled` | the client cancelled the task |
| `:expired` | the ttl of the task ran out |
| `:session_terminated` | the session of the task ended (the option `tasks_follow_session`) |
| `:shutdown` | the host stopped the process of the task (the end of the instance, or a stop of the child) |

Each task gives one `:stop`. The paths that give it: a terminal status
(`completed`, `failed`, `cancelled`), the expiry of the ttl, the end of
the session, a crash of the process and a stop of the child by the
host. The task process traps exits: an exit signal of another process
does not stop the task and the task gives its `:stop` later, when it
ends. A task that the host ends with `Process.exit(pid, :kill)` gives
its `:stop` from the reaper of the tasks: this event has no
`telemetry_span_context` and its `duration` comes from the creation
time of the record of the task.

The callback of a task has no `callback` span: the `task` span covers
it.

## The span of a request to the client

Each request that the server sends to the client (`sampling`,
`elicitation`, roots, `ping`) gives one `client_request` span: a
`:start` before the checks of the capability and of the params and a
`:stop` when the call gives its outcome. A request of a task goes
through the same function, so one span covers the task path too.

The metadata of the span:

| Key | Values |
|---|---|
| `method` | `"ping"`, `"sampling/createMessage"`, `"elicitation/create"`, `"roots/list"`, `"tasks/get"`, `"tasks/result"` or `"tasks/cancel"`, or `:unknown` for a method that the framework does not send to a client |
| `result` (on `:stop`) | `:ok` when the client answered with a result, `:rpc_error` when the client answered a JSON-RPC error, or the atom of the failure: `:timeout`, `:session_terminated`, `:session_not_found`, `:no_stream`, `:session_not_initialized`, `:capability_not_supported`, `:unsupported_method`, `:not_encodable` or `:no_task` |

The `tasks/get`, `tasks/result` and `tasks/cancel` methods are internal to
the flow of a client task. A callback does not send them directly.

The `duration` of the `:stop` is in native time units. A handler
correlates the `:start` and the `:stop` with `telemetry_span_context`.

The `:exception` event is rare, as for the `callback` span: it only
comes from a defect of the framework itself, because the failures of
the request come back as `{:error, _}` and end in the `:stop` event.

## The span of a client task

Each request that the server sends as a task of the client gives one
`client_task` span: a `:start` before the first request and a `:stop`
when the flow gives its outcome. The span covers the `CreateTaskResult`,
the polls and the final result.

Each request of the flow gives its own `client_request` span. A long
poll then gives many `client_request` spans: the `client_task` span is
the one span of the full flow.

The metadata of the span:

| Key | Values |
|---|---|
| `method` | the method of the first request: `"sampling/createMessage"` or `"elicitation/create"`, or `:unknown` for a method that the framework does not send to a client |
| `result` (on `:stop`) | the values of `client_request` and `:client_task_cancelled` when the client task ended with the `cancelled` status, or `:invalid_response` when the client answered a `CreateTaskResult` or a `tasks/get` with a shape that is not a task, or `:client_tasks_disabled` when the runtime option `client_tasks` is `false` (nothing is sent) |

The `:exception` event is rare, as for the `client_request` span: it
only comes from a defect of the framework itself.

## The auth refusal event

Each refusal of the authentication or of the authorization of a request
on the Streamable HTTP transport gives one `[:oz_mcp, :auth, :refused]`
event, before the refusal answer goes out. A request that passes gives
no event. The event is a counter: its only measurement is `count`, with
the value `1`.

The metadata of the event:

| Key | Values |
|---|---|
| `stage` | `authenticate`, `required_scopes` or `authorize` |
| `reason` | the reason of the refusal, in the lists below |

The values of `reason` for each stage:

| `stage` | Values of `reason` |
|---|---|
| `authenticate` | `missing_token` (no usable credential), `invalid_token` (the verifier refused the token), `invalid_request` (a malformed credential: more than one header, a token over the limit), `insufficient_scope` (a scope challenge of the verifier), `token_expired`, `audience_mismatch`, `verifier_error` (the verifier raised, threw, exited, or returned a value of a wrong shape) |
| `required_scopes` | `insufficient_scope` |
| `authorize` | `insufficient_scope`, `forbidden`, `verifier_error` |

An expired token gives `token_expired` and a token for another
resource gives `audience_mismatch`: the refusal answer of both carries
the challenge `invalid_token`, but the event names the cause.

The event never holds a token, a subject or a scope string: the
metadata holds the stage and the reason only, next to the `instance`
and the `server` keys that every event carries. A request that the
router refuses before the credential check (an instance that does not
run, a refused `Host` or `Origin`) is not an authorization refusal and
gives no event.

## The limit event

Each refusal of work because a limit of the server is reached gives one
`[:oz_mcp, :limit, :reached]` event. A replacement of a `GET` stream at
`max_streams_per_session` or a reclaim of an idle session at
`max_sessions` or `max_sessions_per_principal` gives the same event,
with the outcome `replaced`. The event is a counter: its only
measurement is `count`,
with the value `1`. The count of this event shows when to raise a limit:
many events for one limit tell that the work of the clients no longer
fits under the value of its option. Many `replaced` events of
`max_streams_per_session` show a client that opens more streams than it
needs, or that does not close its streams.

The metadata of the event:

| Key | Values |
|---|---|
| `limit` | `max_sessions`, `max_sessions_per_principal`, `max_streams_per_session`, `max_subscriptions_per_session`, `max_tasks_per_session`, `max_tasks_per_principal`, `max_task_records_per_owner` or `max_task_bytes_per_owner` |
| `limit_value` | the value of the option that set the limit |
| `scope` | `instance` for `max_sessions`, `principal` for `max_sessions_per_principal` and `max_tasks_per_principal`, `session` for `max_streams_per_session`, `max_subscriptions_per_session` and `max_tasks_per_session`; for `max_task_records_per_owner` and `max_task_bytes_per_owner`, `principal` or `session` from the owner of the task |
| `outcome` | `refused` (the server refused the work) or `replaced` (the server ended the oldest `GET` stream and opened the new one at `max_streams_per_session`, or ended an idle session at `max_sessions` or `max_sessions_per_principal`) |

The event holds no session id and no principal key: the metadata holds
the limit, the value, the scope and the outcome only, next to the
`instance` and the `server` keys that every event carries. Work under
the limits gives no event and a limit that the value `nil` turned off
gives no event.

## The session restore event

Each attempt to read a session out of the snapshot store gives one
`[:oz_mcp, :session, :restore]` event. An attempt starts when the
request pipeline reads the store and ends when the session starts, or
when the read or the start refuses. A request that names a session
that runs gives no event and an instance with no snapshot module gives
no event.

The event is a counter: its only measurement is `count`, with the value
`1`. The key `outcome` tells how the attempt ended:

| Value | The end that gave it |
|---|---|
| `restored` | the store held the session and the pipeline started it |
| `denied` | the store held the session, but another principal owns it |
| `limit` | the store held the session and a session limit refused the start |
| `unavailable` | the instance did not answer while the start ran |
| `miss` | the store did not hold the session id |
| `cached_miss` | the id is in the cache of the missed ids and the attempt paid no call of the store |
| `deleted` | the id is in the tombstones of the ended sessions (its delete did not end yet, or it failed) and the attempt paid no call of the store |
| `invalid` | the store gave a value that is not a snapshot |
| `failed` | the store raised, threw, exited, or answered an error |

The event holds no session id: the metadata holds the outcome only,
next to the `instance` and the `server` keys that every event carries.

## The snapshot write event

Each write of the snapshot store gives one `[:oz_mcp, :snapshot,
:write]` event, with the time of the write in `duration` (native time
units). The key `action` tells which write ran and the key `result`
how it went:

| Key | Values |
|---|---|
| `action` | `save` (a change of a session), or `delete` (the end of a session) |
| `result` | `ok`, `error` (the store failed), `stopped` (a write that passed its time limit: a save that the delete of its session stopped, or a delete that the store did not answer in time), or `dropped` (a save or a delete that the stop of the instance took with it) |

The writer of the instance runs both actions: the `save` of a change
and the `delete` of a session after the session ended. The event holds
no session id and no snapshot.

## The principal revocation event

Each call of `OzMcp.Sessions.terminate_principal/2` gives one
`[:oz_mcp, :principal, :revoked]` event, after the call ended the
sessions of the principal. The measurement `sessions` holds the count
of the sessions that the call ended. The call for an instance that
does not run gives no event.

The event holds no principal key: the metadata holds the `instance`
and the `server` keys only.

## The subscription dropped event

Each end of a subscription because the scopes of the token of a request
do not cover the scopes that the resource needs gives one
`[:oz_mcp, :subscription, :dropped]` event. The measurement `count`
holds the number of the subscriptions that this check ended. The key
`reason` of the metadata holds `:scope` and no URI and no principal
data goes out: the metadata holds the `instance` and the `server` keys
next to it.

The guide about authorization tells when the check runs and what it
does not see.

## The log dropped event

Each report of the dropped log notifications of one session gives one
`[:oz_mcp, :log, :dropped]` event. A session drops a log over the rate
`max_log_rate`: the drops of one window of one second are counted and
the session emits one event with the count at the end of the window. A
second with no drop gives no event and a session with no drop gives
no event at all.

The event holds no data of the messages that were dropped, no level
and no logger name. The measurement `count` is the number of the
messages that the session dropped in the window. The metadata holds
only the `instance` and the `server` keys that every event carries.
The guide about the notifications describes the rate limit.
