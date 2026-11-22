# Runtime options

This guide gives each option of the child spec `{OzMcp, opts}`. Each
child starts one server in the supervision tree of the host application
and its options configure that server only.

## The child spec

The child spec is `{OzMcp, opts}`, with `opts` a keyword list. Put one
child for each server in the children list of the supervisor of your
application:

```elixir
children = [
  {OzMcp, server: MyApp.McpServer, allowed_origins: ["https://app.example.com"]}
]
```

OzMcp reads the options one time at boot. A value of the wrong type stops
the boot with an `ArgumentError`. A change of an option needs a restart
of the child.

## The keys of the instance

Four keys belong to the instance. The other keys are the options of the
table below.

| Key | Value |
|---|---|
| `server` | the server module. Required |
| `name` | the name of the instance. The default is the server module. Give another name to run one module two times |
| `transport` | `:http` (the default) or `:stdio` |
| `allowed_origins` | the list of the origins of the browsers that can call the server. The default is `[]` |

Each element of `allowed_origins` must be a non-empty string. The boot
refuses the value `"*"`: it is not a wildcard and the router compares
each origin as a string. `OzMcp.Router` uses the list when the plug has
no `allowed_origins` option of its own. A plug option overrides the list.

The guide about the HTTP transport and the guide about the stdio
transport give the details of each transport.

## Several servers

Start one `{OzMcp, ...}` child for each server module:

```elixir
children = [
  {OzMcp, server: MyApp.MarketingServer, allowed_origins: ["https://app.example.com"]},
  {OzMcp, server: MyApp.EngineeringServer, session_timeout_ms: 600_000, allowed_origins: []}
]
```

A child with only the keys of the instance runs with the default
options. Each option that you do not give keeps its default.

## The per-server options

This table gives each option of a server. The column "Check at
boot" gives the check of the value. A value that does not pass the check
stops the boot with an `ArgumentError`.

<!-- generated:options -->

| Option | Default | Check at boot |
|---|---|---|
| `allowed_hosts` | `:any` | see the list below |
| `session_timeout_ms` | `3600000` ms | positive integer |
| `task_page_size` | `50` | positive integer |
| `task_poll_interval_ms` | `nil` ms | positive integer, or `nil` |
| `task_default_ttl_ms` | `nil` ms | positive integer, at most `31536000000`, or `nil` |
| `task_max_ttl_ms` | `86400000` ms | positive integer, at most `31536000000`, or `nil` |
| `request_timeout_ms` | `nil` ms | positive integer, or `nil` |
| `request_cancel_grace_ms` | `1000` ms | positive integer |
| `client_request_timeout_ms` | `60000` ms | positive integer, or `:infinity` |
| `elicitation_timeout_ms` | `300000` ms | positive integer, or `:infinity` |
| `sampling_timeout_ms` | `120000` ms | positive integer, or `:infinity` |
| `client_tasks` | `false` | `true` or `false` |
| `client_task_poll_interval_ms` | `2000` | positive integer |
| `sse_heartbeat_ms` | `15000` ms | positive integer, or `:infinity` |
| `sse_retry_ms` | `1000` ms | positive integer |
| `sse_max_stream_ms` | `nil` ms | positive integer, or `nil` |
| `sse_event_log_size` | `256` | positive integer |
| `sse_event_log_bytes` | `1048576` | positive integer |
| `sse_event_log_session_bytes` | `8388608` | positive integer |
| `sse_event_log_max_streams` | `256` | positive integer, or `nil` |
| `sse_resume_window_ms` | `300000` | non-negative integer |
| `session_init_timeout_ms` | `30000` | positive integer |
| `session_restore_miss_ttl_ms` | `5000` | non-negative integer |
| `max_token_bytes` | `8192` | positive integer |
| `max_body_bytes` | `1048576` | positive integer |
| `max_sessions` | `10000` | positive integer, or `nil` |
| `max_sessions_per_principal` | `100` | positive integer, or `nil` |
| `max_streams_per_session` | `8` | positive integer, or `nil` |
| `max_subscriptions_per_session` | `1000` | positive integer, or `nil` |
| `max_log_rate` | `100` messages per second | positive integer, or `nil` |
| `max_tasks_per_session` | `100` | positive integer, or `nil` |
| `max_tasks_per_principal` | `1000` | positive integer, or `nil` |
| `max_task_records_per_owner` | `1000` | positive integer, or `nil` |
| `max_task_bytes_per_owner` | `67108864` bytes | positive integer, or `nil` |
| `tasks_follow_session` | `true` | `true` or `false` |
| `check_results` | `true` | `true` or `false` |
| `check_output_schemas` | `true` | `true` or `false` |
| `session_snapshot` | `OzMcp.Session.Snapshot.None` | the functions |
| `task_store` | `OzMcp.Tasks.EtsStore` | the functions |
| `pubsub` | `OzMcp.PubSub.Registry` | the functions |
| `telemetry_prefix` | `[:oz_mcp]` | see the list below |
| `resource_url` | `nil` | see the list below |

<!-- /generated:options -->

The jobs of the options:

  * `allowed_hosts`: the hosts that the endpoint accepts in the `Host` header. A list holds the host names; the comparison runs in lower case on the host with no port and the host of an IPv6 request keeps its brackets. A request with another host gets `403`. See the HTTP transport guide (DNS rebinding). The check takes `:any`, or non-empty strings.
  * `session_timeout_ms`: milliseconds of no activity. A session that holds a live stream (`GET` or `POST`), a request in flight, a request to the client, or a running task (with `tasks_follow_session`) does not expire. The timer starts again when the last one ends.
  * `task_page_size`: tasks for each page of `tasks/list`.
  * `task_poll_interval_ms`: milliseconds, or `nil` (no hint). The default of each tool: a tool that declares a `poll_interval` carries its value.
  * `task_default_ttl_ms`: the TTL in milliseconds of a task with no `ttl` of the client; `nil` gives such a task `task_max_ttl_ms`. It must not be higher than `task_max_ttl_ms`.
  * `task_max_ttl_ms`: the cap in milliseconds of the TTL of a task. It caps the `ttl` of the client and the `task_default_ttl_ms` and it is the TTL of a task with no `ttl` and no `task_default_ttl_ms`. `nil` leaves only the ceiling of 365 days.
  * `request_timeout_ms`: milliseconds, or `nil` (no deadline). Every callback runs in its own process under the per-server invoke supervisor. When the deadline elapses, the callback is stopped and the client receives a `-32603` timeout error. Task-backed executions are never deadline-killed: their lifecycle is governed by the task TTL and `tasks/cancel`.
  * `request_cancel_grace_ms`: milliseconds. A callback that traps exits can release its resources and the process is killed when the grace elapses (the exit signal is `shutdown`).
  * `client_request_timeout_ms`: milliseconds, or `:infinity`. A callback waits for the answer of a request that the server sent to the client: `ping` and `roots/list` and any other method that has no timeout of its own. A call can override it with its own `:timeout` option.
  * `elicitation_timeout_ms`: milliseconds, or `:infinity`: a person fills in the form or reads the web page, which takes longer than a machine answer.
  * `sampling_timeout_ms`: milliseconds, or `:infinity`: the client runs a model and may ask its user first.
  * `client_tasks`: `true` lets a callback run a request as a task of the client (experimental). With `false`, a call with `task:` gives `{:error, :client_tasks_disabled}` and sends nothing and `notifications/tasks/status` is ignored. The feature can be removed before 1.0 (see the guide about the requests to the client). `nil` is refused.
  * `client_task_poll_interval_ms`: milliseconds between two polls of a request that the server sends as a task of the client. The `pollInterval` of the client wins and the `:poll_interval` option of the call wins over this option. A floor of `100` ms and a ceiling of `300000` ms apply.
  * `sse_heartbeat_ms`: milliseconds, or `:infinity`. The idle interval of the keep-alive comment of an open stream. The default is 15 s: it stays well under the 60 s idle timeout of many proxies and of Cowboy and on Bandit a gone client is found within one to two heartbeat intervals (the measure of the cost of the interval is in the benchmark folder of the project). The same interval applies to a `POST` response whose request waits for a callback: a response that is still plain JSON becomes an event stream at the first idle interval when the wait asks for it (a `tasks/result` wait does) and an event stream gets the comment chunk. The detection of a gone client depends on the server: one to two heartbeat intervals on Bandit, at once on Cowboy (the HTTP transport guide gives the details). Until the detection, the `GET` stream keeps its slot (a new `GET` over `max_streams_per_session` replaces the oldest stream) and keeps the session out of its idle timer.
  * `sse_retry_ms`: milliseconds. The hint that a stream writes at its start and when it closes, including the close of a `GET` stream, a `POST` stream and the resume of a `POST` stream.
  * `sse_max_stream_ms`: milliseconds, or `nil` (no limit). It applies to a `GET` stream, a `POST` stream and the resume of a `POST` stream. A stream that reaches the limit closes itself with a final `retry:` hint and lets the client poll for new events (SEP-1699).
  * `sse_event_log_size`: events for each stream. Every event of a stream is appended to the log of that stream, newest kept when full. The log of a `POST` stream lives for `sse_resume_window_ms` after the stream is over; the log of a `GET` stream lives for it after the close of its connection; the log that holds the events that no `GET` stream can take lives for it after the session made it. The end of the session (HTTP `DELETE` or expiry) discards each log. When the cap removes events of a stream that a client is about to resume, the client misses them: the server writes a warning log and the client gets a stream with a gap.
  * `sse_event_log_bytes`: bytes for each stream log.
  * `sse_event_log_session_bytes`: bytes for the whole event log of a session. The log of the stream whose newest event is the oldest goes first. The log of the stream that receives an event is never evicted. At least `sse_event_log_bytes`.
  * `sse_event_log_max_streams`: the number of logs of one session. When the number goes over it, the log of the stream whose newest event is the oldest goes first. A client that resumes a stream whose log was evicted gets a gap, or no replay at all when the stream is over. An operator whose clients open many short `POST` streams raises it (no limit).
  * `sse_resume_window_ms`: milliseconds that the log of an ended stream stays for a resume: a `POST` stream after its response, or a `GET` stream after the close of its connection. It is also the time that the events that no `GET` stream can take wait for the next `GET`. `0` drops the log at once and drops the events that no `GET` stream can take. A stream whose connection stopped before its response is over in the same way: its log stays for the window too.
  * `session_init_timeout_ms`: milliseconds to wait for `notifications/initialized`. A session that does not get it stops (HTTP and stdio).
  * `session_restore_miss_ttl_ms`: milliseconds that the cache of the instance holds a session id that the snapshot module did not find. `0` turns the miss cache off; the tombstones of the ended sessions stay.
  * `max_token_bytes`: bytes. `OzMcp.Auth.bearer_token/1,2` refuses a larger token with `400 invalid_request`. A verifier that reads the credential in another way (a gateway header, a cookie, `Plug.Conn.get_req_header/2`) is not limited. The HTTP server (Bandit, Cowboy) has its own limit for the size of a request header: a higher value has no effect above that limit.
  * `max_body_bytes`: bytes of the body of a `POST` request. A body over the limit gets `413`; a body that arrives too slowly gets `408`. The limit is the bound of the memory of the server for one request: a server that accepts large tool arguments sets a higher value. The option belongs to the HTTP transport.
  * `max_sessions`: positive integer, or `nil` (no limit). At the limit, the server ends the idle session with the oldest activity, then starts the new one. A session that never sent `notifications/initialized` goes first. A session that is not idle, as `session_timeout_ms` defines it, is never ended. When no session is idle, `initialize` gets `429` with the JSON-RPC error `-32000 "too many sessions"`. The client of an ended session gets `404` and sends `initialize` again. A session that expired is gone and no longer counts.
  * `max_sessions_per_principal`: positive integer, or `nil` (no limit). The key of the principal is `{issuer, subject}`. A restore from a snapshot counts in this limit. A DELETE does not. The limit has no effect on a server with no authorization. At the limit, the rule of `max_sessions` applies among the sessions of the principal. The count is local to the node.
  * `max_streams_per_session`: positive integer, or `nil` (no limit). Only the live `GET` streams count. The `POST` response streams do not. A `GET` over the limit ends the oldest `GET` stream of the session (a last `retry:` hint and its events stay for `sse_resume_window_ms`) and opens the new one.
  * `max_subscriptions_per_session`: subscriptions of one session. A new URI over the limit gets the error `-32000 "too many subscriptions"` with `data.limit` `max_subscriptions_per_session` in a `200` answer. A repeat subscribe of a URI that the session already holds is not a new subscription. A session that comes back from a snapshot with more subscriptions keeps them: the limit applies to a new URI only.
  * `max_log_rate`: log notifications (`notifications/message`) that one session accepts for each second. The bucket of a session starts full: the burst is `max_log_rate` messages. A message over the rate is dropped: the caller gets `:ok` and the drops of one second give the event `[:oz_mcp, :log, :dropped]` once. A message that the level refuses uses no token. The limit applies to the logs of a task too. `nil` sets no limit.
  * `max_tasks_per_session`: tasks of one session that run at the same time (`working` or `input_required`); a call over the limit gets `-32000 "too many tasks"` with `data.limit` `max_tasks_per_session`. `nil` sets no limit.
  * `max_tasks_per_principal`: tasks of one principal that run at the same time, in all its sessions. A call over the limit gets `-32000 "too many tasks"` with `data.limit` `max_tasks_per_principal`. `nil` sets no limit. The limit has no effect on a server with no authorization.
  * `max_task_records_per_owner`: task records of one owner, active and terminal. A call over the limit gets `-32000 "too many tasks"` with `data.limit` `max_task_records_per_owner`. `nil` sets no limit. It must not be lower than `max_tasks_per_session` or `max_tasks_per_principal`.
  * `max_task_bytes_per_owner`: the budget in bytes of the task records of one owner. A call over the budget gets `-32000 "too many tasks"` with `data.limit` `max_task_bytes_per_owner`. The limit is soft: a result that comes after the check can pass it. `nil` sets no limit.
  * `tasks_follow_session`: when `true`, the end of a session stops its tasks that run. When `false`, a task goes on after its session and a new session of the principal can read its result and answer its requests to the client. A server with no authorization has no principal: the tasks guide gives that case. `nil` is refused.
  * `check_results`: when `true`, the framework checks the result of every callback (the shape of the method, the `_meta` keys, the JSON terms) and gives the client `-32603` for a bad one. When `false`, a map result goes to the client as it is and a struct result keeps the rules of its `build/1`, so a bad struct still gives `-32603`; a result that is not JSON still gives `-32603` when the answer is encoded. The error path of a callback (an `{:error, ...}` answer, a raise, a deadline overrun) keeps its checks. See the guide about the declaration of a server. `nil` is refused.
  * `check_output_schemas`: when `true`, the `structuredContent` of a tool that declares an `outputSchema` must agree with it, or the client gets `-32603`. When `false`, the framework does not check it: a `structuredContent` that does not agree with the schema reaches the client and giving one is the job of the server author. The `outputSchema` stays in `tools/list`. `nil` is refused.
  * `session_snapshot`: a module of the behaviour `OzMcp.Session.Snapshot`. The default keeps nothing. The check needs the functions `save/3`, `load/2` and `delete/2`.
  * `task_store`: a module of the behaviour `OzMcp.Tasks.StoreBehaviour`. The contract needs four required functions (`init/1`, `put/2`, `get/2`, `delete/2`). Five more callbacks are optional (`page/4`, `count_active/2`, `expired/3`, `next_expiry/1`, `owner_usage/2`): a store must implement all five or none of them and the boot refuses a partial set. With none of them, the index of the records lives in the memory of the node and starts empty at a restart. A store that keeps its records after a restart must implement the five optional callbacks itself. The check needs the functions of the contract.
  * `pubsub`: a module of the behaviour `OzMcp.PubSub` that sends the broadcasts to the sessions. It may export the optional `child_specs/1`: the instance starts the child specs that it returns after the `Topics` Registry. OzMcp does not read the subscribers. `terminate_principal/2` does not use this module. `OzMcp.PubSub.Registry` sends to the sessions of the local node only. `OzMcp.PubSub.PG` starts a `:pg` scope and sends to the sessions of every connected node that runs the same instance. The check needs the functions `subscribe/2`, `unsubscribe/2` and `broadcast/3`.
  * `telemetry_prefix`: the prefix of the event names of the instance. Two instances can share one prefix: the metadata `instance` of each event tells their events apart. See the guide about telemetry. The check needs a non-empty list of atoms.
  * `resource_url`: canonical URL. It identifies this MCP server as a resource to the authorization server and the clients (RFC 8707). Set it to the public URL and serve the endpoint behind TLS: a proxy that changes the host or the scheme is invisible from the inside, so the URL is never guessed from the request. OzMcp reads it once at boot, so a release can take it from the environment. OzMcp stores the scheme and the host in lower case: `http` is allowed for `localhost`, `127.0.0.1` and `::1` only. OzMcp publishes it in the static opts of the server, together with the URL of the Protected Resource Metadata document built from it. The check is required with an `authorization` block, refused without it.

The groups of options have this job:

  * Sessions: the options `session_timeout_ms`, `session_init_timeout_ms`,
    `session_snapshot`, `session_restore_miss_ttl_ms` and the limits
    `max_sessions`, `max_sessions_per_principal`,
    `max_streams_per_session`, `max_subscriptions_per_session` and
    `max_log_rate`. The rate limit of the logs gives the event
    `[:oz_mcp, :log, :dropped]`, not `[:oz_mcp, :limit, :reached]`.

  * Run of the callbacks: the options `request_timeout_ms`,
    `request_cancel_grace_ms`, `client_request_timeout_ms`,
    `elicitation_timeout_ms`, `sampling_timeout_ms`, `client_tasks`,
    `client_task_poll_interval_ms`, `check_results` and
    `check_output_schemas`.

  * Streams: the options `sse_heartbeat_ms`, `sse_retry_ms`,
    `sse_max_stream_ms` and `sse_event_log_size`. They apply to a `GET`
    stream, a `POST` stream and the resume of a `POST` stream.

  * Event log: the options `sse_event_log_bytes`,
    `sse_event_log_session_bytes`, `sse_event_log_max_streams` and
    `sse_resume_window_ms`. Each
    stream has its own log: the stream of a `POST` response, a `GET`
    stream and the stream that holds the events that wait for the
    next `GET`. The total of the logs of a session stays under
    `sse_event_log_session_bytes` plus `sse_event_log_bytes`: the worst
    case is a session whose only log over the budget is the log of the
    stream that receives an event.

  * Tasks: the options `task_store`, `task_default_ttl_ms`,
    `task_max_ttl_ms`, `task_poll_interval_ms`, `task_page_size`,
    `max_tasks_per_session`, `max_tasks_per_principal`,
    `max_task_records_per_owner` and `max_task_bytes_per_owner`.

  * Authorization: the options `resource_url` and `max_token_bytes`.

  * Telemetry: the option `telemetry_prefix`, the prefix of the names
    of the events. The guide about the telemetry gives the events.

Each session has its own idle timer: it ends a session with no
activity after `session_timeout_ms`. A client that sends `initialize` over
`max_sessions` or `max_sessions_per_principal` and meets no idle session
gets the status `429`. Each refusal of one of the eight limits
(`max_sessions`, `max_sessions_per_principal`, `max_streams_per_session`,
`max_subscriptions_per_session`, `max_tasks_per_session`,
`max_tasks_per_principal`, `max_task_records_per_owner` and
`max_task_bytes_per_owner`) gives the event
`[:oz_mcp, :limit, :reached]` of the telemetry and the replacement of
a `GET` stream at `max_streams_per_session` or the reclaim of an idle
session at `max_sessions` or `max_sessions_per_principal` gives the
same event with the outcome `replaced`. The count of this event shows
when to raise a limit. The deadline of `request_timeout_ms` does not apply to a
task-backed call. The event logs of the streams of a session give the
resume with the `Last-Event-ID` header. The guide about the tasks gives the
details of the task options. The guide about the authorization gives
the details of `resource_url` and `max_token_bytes`.

The boot checks the names of the keys. An unknown key, for example a
key with a typo, stops the boot with an `ArgumentError` that lists the
known options.

## A full example with two servers

The module `MyApp.McpChildren` builds the children. The example
application of this project runs the two servers of the guide about the
servers. `MyApp.EngineeringServer` declares an `authorization` block, so
it must give `resource_url`:

```elixir
defmodule MyApp.McpChildren do
  @moduledoc false

  def children do
    [
      {OzMcp,
       server: MyApp.EngineeringServer,
       allowed_origins: ["https://app.example.com"],
       resource_url: System.fetch_env!("ENGINEERING_MCP_URL"),
       session_timeout_ms: 600_000,
       max_sessions: 1_000,
       max_sessions_per_principal: 5,
       request_timeout_ms: 30_000,
       elicitation_timeout_ms: 120_000,
       sse_heartbeat_ms: 15_000,
       task_default_ttl_ms: 600_000,
       task_max_ttl_ms: 3_600_000},
      {OzMcp, server: MyApp.MarketingServer, allowed_origins: ["https://app.example.com"]}
    ]
  end
end
```

The application adds the children to its own list:

```elixir
children =
  MyApp.McpChildren.children() ++
    [{Bandit, plug: MyApp.Router, ip: {127, 0, 0, 1}, port: 4000}]
```

`MyApp.MarketingServer` has no other option, so this server runs with
the default options.

## The options that OzMcp refuses

OzMcp refuses these options at boot, with an `ArgumentError`:

  * An option that OzMcp does not know, for example a misspelled name.
    The message lists the known options.
  * `resource_url` on a server with no `authorization` block. A server
    with the block must give `resource_url`. OzMcp refuses to boot
    without it.

The boot also refuses these values of an option, with an `ArgumentError`
that names the option and the value:

  * `session_timeout_ms` that is not a positive integer (ms).
  * `task_page_size` that is not a positive integer.
  * `task_poll_interval_ms` that is not a positive integer (ms) or `nil`.
  * `tasks_follow_session`, `client_tasks`, `check_results` or
    `check_output_schemas` that is not `true` or `false`. `nil` is
    refused.
  * `task_default_ttl_ms` higher than `task_max_ttl_ms`. Without a
    `task_max_ttl_ms` of its own, the default cap of 24 h is the cap: a
    `task_default_ttl_ms` above it is refused too.
  * `task_default_ttl_ms` or `task_max_ttl_ms` above `31536000000`
    (365 days).
  * `max_tasks_per_session` or `max_tasks_per_principal` higher than
    `max_task_records_per_owner`. The record limit must be able to hold
    the active tasks that the other limits allow.

Limits: the options `max_sessions` (default `10000`),
`max_sessions_per_principal` (default `100`),
`max_streams_per_session` (default `8`),
`max_subscriptions_per_session` (default `1000`),
`max_tasks_per_principal` (default `1000`),
`max_task_records_per_owner` (default `1000`) and
`max_task_bytes_per_owner` (default 64 MiB) protect the node: an open
server cannot grow without a cap and one principal cannot hold all of
it. An open server that has no authorization should still have a rate
limit in front of it: a flood of `initialize` can end the idle sessions
of good clients. The value `nil` turns one limit off:

```elixir
{OzMcp,
 server: MyApp.Server,
 max_sessions: 50_000,
 max_sessions_per_principal: nil,   # no limit for each principal
 max_streams_per_session: 2,
 max_subscriptions_per_session: 100}
```

## Read the values from the environment of a release

A release must not hold the secrets and the URLs in the code. Put the
options in the file `config/runtime.exs`. The system loads this file
at the start of the release. The file can read the variables of the
environment:

```elixir
# config/runtime.exs
import Config

config :my_app, :engineering_mcp,
  server: MyApp.EngineeringServer,
  allowed_origins: ["https://app.example.com"],
  resource_url: System.fetch_env!("ENGINEERING_MCP_URL"),
  session_timeout_ms: 600_000
```

The application reads the value from its environment:

```elixir
children = [
  {OzMcp, Application.fetch_env!(:my_app, :engineering_mcp)},
  {Bandit, plug: MyApp.Router, ip: {127, 0, 0, 1}, port: 4000}
]
```

`System.fetch_env!/1` stops the start of the release when the variable
does not exist. This is usually what you want: the release cannot serve
the requests without the URL of the endpoint.
