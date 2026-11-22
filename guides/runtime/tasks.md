# Tasks

This guide describes the tasks: a `tools/call` that answers at once
and a tool that runs in the background. The guide about the runtime
options gives the task options of the runtime config. The guide about
the requests to the client describes the requests that a callback sends
to the client.

## What a task is

A task is a `tools/call` with a `task` key in the params. The server
answers at once with a task record and the tool runs in the
background. The client reads the state of the task and collects the
result of the tool when the task ends.

The methods of the tasks are:

| Method | Job |
|---|---|
| `tools/call` with `task` | creates the task and answers with the task record |
| `tasks/get` | reads one task record |
| `tasks/list` | lists the tasks of the owner, one page at a time |
| `tasks/result` | waits for the end of the task and gives the result of the tool |
| `tasks/cancel` | stops a task that runs |

Use a task for a tool that runs for a long time: an export of many
rows, a job on a slow external system, a batch that a person follows.
A request that runs as a task has no deadline of its own: the option
`request_timeout_ms` does not stop it. The life of the task bounds it (see
the options below).

## The procedure

A server runs a tool as a task only when three things are true:

1. The server declares `tasks` in its `capabilities` block, with
   `requests.tools.call`.
2. The tool declares `task_support "optional"` or `"required"` in its
   `execution` block.
3. The client adds the key `task` to the params of `tools/call`.

### The capability

Write the `tasks` block in the `capabilities` block of the server
module:

```elixir
defmodule MyApp.TasksServer do
  use OzMcp.Config.Server

  server_info do
    name "tasks-server"
    version "1.0.0"
  end

  capabilities do
    tasks do
      list %{}
      cancel %{}
      requests %{tools: %{call: %{}}}
    end
  end

  tools do
    tool MyApp.Tools.ExportTool
  end
end
```

The three keys of the `tasks` block enable the methods:

| Key | Method that it enables |
|---|---|
| `list %{}` | `tasks/list` |
| `cancel %{}` | `tasks/cancel` |
| `requests %{tools: %{call: %{}}}` | `tools/call` with a `task` key |

Without the `tasks` capability, each `tasks/*` request gives the error
`-32601` to the client. Without `list`, `tasks/list` gives `-32601`.
Without `cancel`, `tasks/cancel` gives `-32601`. The methods
`tasks/get` and `tasks/result` need the `tasks` capability only.

A server that declares no `requests.tools.call` applies no task rule to
`tools/call`: the server removes the key `task` from the params and
each tool runs plain. Declare the three keys when the server runs
tasks. A tool with `task_support "optional"` or `"required"` on such a
server gives a warning at boot. See [the guide of the tools](../entities/tools.md).

### The tool

Write the `task_support` value in the `execution` block of the tool:

```elixir
execution do
  task_support "optional"
end
```

The value decides how the client can call the tool:

| `task_support` | Call without `task` | Call with `task` |
|---|---|---|
| `"forbidden"` (the default) | the tool runs plain | `-32601` |
| `"optional"` | the tool runs plain | the tool runs as a task |
| `"required"` | `-32601` | the tool runs as a task |

A value that is not `"forbidden"`, `"optional"` or `"required"` stops
the compilation. A `task` value that is not a map, or a `ttl` that is
not a positive integer, gives the error `-32602` to the client. A JSON
`null` for an optional member of the request is the same as a missing
member: `"task": null` does not run the tool as a task and `"task":
{"ttl": null}` runs it as a task with the default TTL.

The server removes the key `task` from the params before it calls the
callback. The callback never reads it.

### The callback

Write `call/2` as usual. In a task-backed execution, the map `ctx`
carries a `task_id` that is not `nil`. The result of the callback
becomes the result of the task. The client collects it with
`tasks/result`.

The result of the callback must have the same shape as the result of a
plain call: a `%CallToolResult{}` struct (or its wire map), or a map
that follows the shape rule of the tools guide. The result of a task
tool gets the same shape check as the result of a direct call. A result
of another shape (for example `{:ok, %{}}` or `{:ok, "text"}`) makes a
`failed` task with the status message `internal error`. A
`tasks/result` request for such a task gives the error `-32603`, with
the message `internal error`. The detail of the failure goes to the
server log.

The example of this guide is a tool that runs as a task only. It
reports the progress of each page and it writes a status message at
the end:

```elixir
defmodule MyApp.Tools.ExportTool do
  use OzMcp.Config.Tool

  alias OzMcp.Tasks.Context, as: TaskContext

  tool "export_tickets" do
    title "Export the tickets"
    description "Export all the tickets of a team to a CSV file"

    input_schema %{
      type: "object",
      properties: %{team: %{type: "string", minLength: 1}},
      required: ["team"]
    }

    execution do
      task_support "required"
    end
  end

  @impl true
  def call(ctx, %{"name" => "export_tickets", "arguments" => %{"team" => team}}) do
    pages = 5

    for page <- 1..pages do
      Process.sleep(1_000)
      TaskContext.progress(ctx, page, pages, "Page #{page} of #{pages}")
    end

    TaskContext.status_message(ctx, "Write the file")

    {:ok,
     %{content: [%{type: "text", text: "The tickets of #{team} are in export-#{team}.csv"}]}}
  end
end
```

The progress value must increase with each call: a value that is equal
to or smaller than the last one is dropped and the client gets nothing.

The client sends this request:

```json
{"jsonrpc": "2.0", "id": 3, "method": "tools/call",
 "params": {"name": "export_tickets", "arguments": {"team": "core"},
            "task": {"ttl": 600000}}}
```

The `ttl` of the `task` object is optional. The server answers at once
with the task record:

```json
{"jsonrpc": "2.0", "id": 3, "result": {"task": {
  "taskId": "aB3dEf7hIj9kLm2nOp4qRs6tUv8wXyZ0",
  "status": "working",
  "createdAt": "2026-10-20T09:00:00Z",
  "lastUpdatedAt": "2026-10-20T09:00:00Z",
  "ttl": 600000,
  "pollInterval": 2000}}}
```

The `pollInterval` of the record is the hint of the tool. A tool can
declare its own interval with `poll_interval` in the `execution` block
of the DSL. The option `task_poll_interval_ms` of the server is the hint
of the tools that declare none. `tools/list` never shows the interval
of a tool: the hint goes out with the task records only.

A tool with `task_support "optional"` handles the two modes in the same
callback. The helper functions of `OzMcp.Tasks.Context` return
`{:error, :not_a_task}` when the tool runs plain. Test `ctx.task_id`:

```elixir
defp report(ctx, step, total) do
  cond do
    ctx.task_id != nil ->
      # Task-backed execution: the task owns the progress token.
      OzMcp.Tasks.Context.progress(ctx, step, total, "step #{step}")

    ctx.progress_token != nil ->
      # Plain execution: the token is the token of this request.
      OzMcp.Notify.progress(
        ctx.server,
        ctx.session_id,
        ctx.progress_token,
        step,
        total: total,
        message: "step #{step}"
      )

    true ->
      :ok
  end
end
```

The task owns the progress token: the server takes the
`_meta.progressToken` of the request that created the task. The
callback never passes a token to `TaskContext.progress/4`. Nothing is
sent when that request carried no token. The
notification carries the `io.modelcontextprotocol/related-task`
`_meta` with the id of the task.

`OzMcp.Tasks.Context.progress/4` and `OzMcp.Notify.progress/3` with the
ctx of the task are the same call: both go through the same internal
function of `OzMcp.Tasks`. Both check the `total` and the `message`
before the send: a value that JSON cannot encode (a pid, a tuple, a
string that is not valid UTF-8) gives `{:error, :not_encodable}` and
nothing is sent.

The helpers of `OzMcp.Tasks.Context` are:

| Function | Job |
|---|---|
| `progress/4` | sends `notifications/progress` for the task |
| `status_message/2` | changes the `statusMessage` of the task record. No notification: `tasks/get` gives the new message. A text that JSON cannot encode gives `{:error, :not_encodable}` and the task keeps its old message |

The status, progress and log messages of a task go to the owner of the
task (the principal that created it, or its session when the server has
no authorization). An open `tasks/result` request for the task
receives each message on each of its streams. Without an attached
stream, every session of the owner receives the message: with
authorization the server sends it to the topic of the principal,
without it to the session of the task. A log message
(`OzMcp.Notify.log/3` with the ctx of the task) carries the
related-task `_meta` and the level of each receiving session (set with
`logging/setLevel`) decides alone whether that session gets it. The
session that receives it limits the rate of the logs too: a flood of
logs from a task drops the messages over `max_log_rate`, as for the
other logs (the guide about the notifications describes the rate).

Two limits of the route without an attached stream:

  * The topic of the principal does not filter by scope. A session
    whose token does not hold the scopes of the task can receive the
    status of the task. It cannot read the task: `tasks/get`,
    `tasks/result`, `tasks/cancel` and `tasks/list` check the scopes.
  * The progress token of a task comes from the request that created
    the task. A session that did not create the task can receive a
    `notifications/progress` with a token that its own request did not
    carry. A client ignores a token that it does not know.

## The states

A task has five statuses:

| Status | Meaning |
|---|---|
| `working` | the tool runs |
| `input_required` | the task waits for the answer of the client |
| `completed` | the tool answered. Terminal |
| `failed` | the tool crashed, or the task was lost in a restart. Terminal |
| `cancelled` | the client cancelled the task. Terminal |

The legal transitions are:

| From | To |
|---|---|
| `working` | `input_required`, `completed`, `failed`, `cancelled` |
| `input_required` | `working`, `completed`, `failed`, `cancelled` |

Each transition sends `notifications/tasks/status` to the owner of the
task. The notification carries the task record. An open `tasks/result`
request for the task receives the event on each of its streams. Without
an attached stream, every session of the owner receives the event and
each session writes it on one stream of the session: the `GET` stream,
or the stream of a `POST` response. A task that a session owns (a
server with no authorization) sends the event to its session only.

A crash of the task manager marks each task that lost its runner as
`failed`. A crash of `:tasks` stops the tasks that it runs and each one
gets the message "The task process crashed."; the record stays and the
client receives the status notification. A crash of `Core` or of
`PubSub` stops `Workers` and each task gets the message "The server
stopped the task.". With the default store, a crash of `Core` also
deletes the record, so a client that reads the task gets no status.

A runner that ends with an abnormal reason also makes the task
`failed`. The status message is then always the same: "The task runner
crashed.". The reason of the end goes to the log only, next to the id
of the task. It can hold the text of an exception and a stack trace,
so it never goes to the client. A task whose runner cannot start is
`failed` in the `CreateTaskResult` and no status notification goes
out for it.

The runner of the tool stops with the process of the task. This is also
true when the process of the task ends in an abnormal way: the runner
is linked to the task, so a stop of the task stops the runner. The
exception is a callback that traps exits: such a callback receives the
end of the task as a message and can go on.

The telemetry gives one `task` span for each task: the `:stop` event
comes from the terminal status, the expiry of the ttl, the end of the
session, a crash of the process, or a stop of the child by the host. A
killed task gets its `:stop` from the reaper and this event has no
`telemetry_span_context`. The guide about the telemetry lists the
events and their metadata.

A task that the supervisor stops (a stop of the child, a stop of
`Workers`, or a stop of the instance) gets the status `failed` and the
message "The server stopped the task.". A restart of the reaper stops no task. The reaper marks a
record with a dead process as `failed` when it starts and it monitors
the processes that still run again.

## The methods

### tasks/get

`tasks/get` reads the task record. The params give the `taskId`:

```json
{"jsonrpc": "2.0", "id": 4, "method": "tasks/get",
 "params": {"taskId": "aB3dEf7hIj9kLm2nOp4qRs6tUv8wXyZ0"}}
```

The answer carries the task record. An unknown `taskId`, or a
`taskId` of another owner (a task of another principal, or of another
session on a server with no authorization), gives the error `-32602`. A
task that passed its TTL gives the error `-32602` too.

### tasks/list

`tasks/list` gives the tasks of the owner, one page at a time. The
params `cursor` and `limit` are optional. Without `limit`, the page has
`task_page_size` tasks (`50` by default). The answer gives the tasks
and a `nextCursor` when a next page exists. An invalid cursor gives
the error `-32602`.

The list holds the tasks of one owner only: with authorization the
tasks of the principal of the request, without it the tasks of the
session. A task whose scopes the token of the session does not hold is
left out of the list.

### tasks/result

`tasks/result` waits until the task reaches a terminal status and
gives the result of the tool:

```json
{"jsonrpc": "2.0", "id": 5, "method": "tasks/result",
 "params": {"taskId": "aB3dEf7hIj9kLm2nOp4qRs6tUv8wXyZ0"}}
```

The wait has no time limit of its own. The response of the request
becomes an event stream after an idle interval and heartbeat comments
keep the connection open (the option `sse_heartbeat_ms`). At
`sse_max_stream_ms` the stream closes itself with a `retry:` hint and
the client resumes it. The session
gives the id of each event of the stream and the events of the stream
(the requests of the task, the notifications about it) stay in the log
of the stream: a client that loses the connection can resume it with
`Last-Event-ID` (the HTTP transport guide describes the resume). The
wait
ends at the first of these events:

  * the task reaches a terminal status. A task that ends `completed`
    gives the result of the tool. The answer carries the
    related-task `_meta`.
  * the task expires. The error is `-32602`.
  * the session ends. The error is `-32000`. This is true for each value
    of `tasks_follow_session`. With `false`, the task goes on after the
    end of the session: a new `tasks/result` request of another session
    of the owner gets the requests that the task still holds and the
    result of the task.
  * the task is `cancelled` (by `tasks/cancel`). The error is `-32800`
    with the message `task was cancelled` and the related-task `_meta`
    in `data`.
  * the client cancels the `tasks/result` request itself
    (`notifications/cancelled`). The error is `-32800` with the message
    `request cancelled`. The task is not touched: only `tasks/cancel`
    cancels a task.

A wait that outlives the token of its request closes its stream with a
`retry:` hint at the expiry of the token (the authorization guide). The
task is not stopped. The client resumes the stream with a new token and
`Last-Event-ID` to get the outcome.

A `tasks/result` request for a task that is already terminal gives the
stored result at once. The record of a task that is `completed` stays
until the end of its TTL: the client can read the result again, or
with a second client call after a lost connection.

An unknown `taskId` gives the error `-32602`.

A process of the server can wait for a task with
`OzMcp.Tasks.await/4`. The timeout is a number of milliseconds, or
`nil` for no limit (the same as `await/3`). The wait gives
`{:error, :timeout}` when the limit passes.

```elixir
{:ok, result} = OzMcp.Tasks.await(instance, owner_key, task_id, 5_000)
```

### tasks/cancel

`tasks/cancel` stops a task that runs. The server stops the runner of
the tool, moves the task to `cancelled` and answers with the task
record in the status `cancelled`. The cancel happens before the
answer.

A task that is already terminal gives the error `-32602`. An unknown
`taskId` gives the error `-32602`.

After the cancel, a `tasks/result` request for the task gives the error
`-32800` with the message `task was cancelled`. The `data` of the error
carries the related-task `_meta`. The code is not `-32603`: a cancel is
an action of the client and not a failure of the server. A
`tasks/result` request that is open at the time of the cancel gets the
same error.

The requests of the task that wait for the client (an elicitation, for
example) get `notifications/cancelled` on the `tasks/result` stream:
the client closes the form.

`notifications/cancelled` for a `tools/call` request does not cancel a
task. Only `tasks/cancel` cancels a task.

## Elicitation and sampling in a task

A task can send requests to the client: an elicitation, a
`sampling/createMessage` request, a `roots/list`. The task runs
detached: no `POST` request carries its messages. The requests travel
on the `tasks/result` stream of the task:

1. The callback calls `OzMcp.Client.elicit/3` (or `sample/3`, or
   `list_roots/2`). The task moves to `input_required` and the
   request waits.
2. The server writes the request on the response of an open
   `tasks/result` request for the task. The request carries the
   related-task `_meta`.
3. The client answers with a `POST` that carries the JSON-RPC
   response. The callback receives the answer and the task moves back
   to `working` when no request of it waits.

When no `tasks/result` request is open, the request of the task waits.
The timeout of the method applies (`elicitation_timeout_ms`,
`sampling_timeout_ms` or `client_request_timeout_ms`). The task does not
fail: after the timeout, the task goes on and the callback can ask
again. A client that calls `tasks/result` later receives the requests
that are still unanswered.

Any session of the owner can answer a request of a task: the client
that answers does not need the session that created the task. The id
of a request of a task (`t.<task_id>.<n>`) is not a part of the
protocol: read it from the request on the stream and answer with the
same id.

The server sends a request of a task only on the streams whose client
declared the capability that the request needs (`elicitation`, for
example; the guide about the requests to the client gives the
capability of each method). A stream whose client did not declare it
receives no request: the request waits until a stream that accepts it
is open, or until the timeout of the method.

The status `input_required` is automatic: the task has it while it
holds a request to the client and no helper sets it. A tool that
waits for an input of another channel keeps the status `working` and
tells the wait with `TaskContext.status_message/2`.

A callback of a task can also send a request as a task of the client
(`task:` in `OzMcp.Client.sample/3` and `elicit/3`; the runtime option
`client_tasks`, off by default; the guide about the requests to the
client describes it). The polls of the client task
(`tasks/get`, `tasks/result`, `tasks/cancel`) are requests of the
server task, but they do not need the client to act on the server
task. While a `tasks/result` stream can carry a poll, the server task
stays `working`. With no stream that can carry it, the poll makes the
server task `input_required`: the client calls `tasks/result`, reads
the poll and its answer moves the task back to `working`. A stream
that ends while a poll waits also makes the server task
`input_required`. A client that closes its stream after each answer
then works, at one cycle for each poll. The first request (with
`params.task`) is not neutral: the server task is `input_required`
until the `CreateTaskResult`.

The client task is not the server task. The server task ends when the
callback ends; the client task runs on the client and ends at its
`ttl`, or when the server sends `tasks/cancel`.

## The options

The options of a server entry control the tasks:

| Option | Default | Job |
|---|---|---|
| `task_store` | `OzMcp.Tasks.EtsStore` | the module that holds the task records |
| `task_default_ttl_ms` | `nil` | the TTL (ms) of a task that the client created with no `ttl` of its own. `nil` sets no limit of its own: such a task gets `task_max_ttl_ms`. The boot refuses a value above `31536000000` (365 days) |
| `task_max_ttl_ms` | `86400000` (24 h) | the cap (ms) of the TTL of a task. It caps the `ttl` of the client and the `task_default_ttl_ms` and it is the TTL of a task with no `ttl` and no `task_default_ttl_ms`. `nil` leaves only the ceiling of 365 days. The boot refuses a value above `31536000000` (365 days) |
| `task_poll_interval_ms` | `nil` | the `pollInterval` hint (ms) that each task record carries. It is the default of each tool: the tools that declare a `poll_interval` of their own carry their value. `nil` gives no hint |
| `task_page_size` | `50` | the page size of `tasks/list` when the client gives no `limit` |
| `max_tasks_per_session` | `100` | the tasks of one session that can run at the same time. `nil` sets no limit |
| `max_tasks_per_principal` | `1000` | the tasks of one principal that can run at the same time, in all its sessions. `nil` sets no limit |
| `max_task_records_per_owner` | `1000` | the task records of one owner, active and terminal. A create over the limit gets `-32000 "too many tasks"` with `data.limit` `max_task_records_per_owner`. `nil` sets no limit |
| `max_task_bytes_per_owner` | `67108864` (64 MiB) | the byte budget of the task records of one owner. A create over the budget gets `-32000 "too many tasks"` with `data.limit` `max_task_bytes_per_owner`. The limit is soft. `nil` sets no limit |
| `tasks_follow_session` | `true` | `true`: the end of a session stops its tasks that run. `false`: a task goes on after its session |

The server resolves the TTL of a task at the creation: the `ttl` of
the client, else `task_default_ttl_ms`, else `task_max_ttl_ms`,
capped by `task_max_ttl_ms`, then by the ceiling of 365 days
(`31536000000` ms). The value `nil` of `task_max_ttl_ms` means no cap
other than the ceiling: a task whose TTL has no source then never
expires.

The reaper ends each task that passed its TTL. It stops the task process, deletes the record and answers the waiters
of `tasks/result` with the error `-32602`. The `pollInterval` hint
tells the client to poll `tasks/get` at this interval. Each task
record carries the hint of its tool: the `poll_interval` that the
execution block of the tool declares, or `task_poll_interval_ms` when the
tool gives none.

The task records live in the store of `task_store`. The default store
keeps the records in an ETS table. A crash of the owner of the tables
deletes the records of the server: a crash of `Core` restarts the
owner. A crash of the supervisor of the sessions or of the supervisor
of the callbacks does not delete the records. The default store is
local to a node: a `tasks/get` on another node finds nothing. Give a
custom store (`OzMcp.Tasks.StoreBehaviour`) when the tasks must survive
a restart or when the server runs on many nodes (see the guide
[Run many nodes](cluster.md)).

The contract of the store has four required functions (`init/1`,
`put/2`, `get/2`, `delete/2`) and the boot checks them. Five more
callbacks are optional: `page/4` (the pages of `tasks/list`),
`count_active/2` (the checks of the limits), `expired/3` with
`next_expiry/1` (the work of the reaper) and `owner_usage/2` (the
counts of the records and of the bytes of each owner, for the record
limits). A store must implement all five or none of them: the boot
refuses a partial set. With none of them, the index of the records
(the pages, the expiry, the counters of the active tasks and the
counts of the records and of the bytes of each owner) lives in the
memory of the node and it starts empty at a restart: such a store
cannot keep its records after a restart and several nodes cannot
share it. A store that keeps its records after a restart, or that
several nodes share, must implement the five optional callbacks
itself. A store that implements them owns its index: the facade
OzMcp.Tasks.Records calls it and no default index runs beside it.

The field `seq` of a record comes from `System.unique_integer/1`. It
starts again at 1 each time the VM starts, so it is not unique across
restarts. The cursor of `tasks/list` is the `seq` of the last record of
the page. A store that keeps its records after a restart must give
`page/4` an order that does not depend on `seq`, or it must give the
records a new `seq` when it loads them. The default store loses all its
records at a restart, so it has no problem.

The recovery of the records at a start needs the optional callback
`active/1` of the store. The reaper calls it one time when it starts.
It marks each record whose process is dead as `failed` and it
monitors the processes that still run. A store that does not implement
`active/1` gets no recovery at the start: a task that ended with no
write of its own stays `working` until the client cancels it, or until
its ttl expires. A store that keeps its records after a restart needs
this callback most. A restart of the reaper loses the monitors of the
running tasks when the store has no `active/1`. The reaper ignores a
record whose process is on another node: the reaper of that node owns
the task.

## The limits

The tasks belong to the principal of the request that created them. A
server with no authorization has no principal: its tasks belong to the
session. On such a server, with `tasks_follow_session` at `false`, a
task goes on after the end of its session and no session can read its
result.

  * The sessions of one principal read, cancel and wait for the same
    tasks. A `taskId` of another owner gives the error `-32602`, the
    same as an unknown task.
  * With `tasks_follow_session` at `true` (default), the tasks end with
    the session that started them. The end of the session is the HTTP
    `DELETE`, the expiry of the session, or a revocation. The end
    stops the runners of its tasks and answers the waiters of
    `tasks/result` with the error `-32000`. With `false`, a task goes
    on after the end of its session and a new session of the same
    principal reads its result. A task that goes on can still ask the
    client: the request goes on the `tasks/result` stream of any
    session of the principal and any session of the principal can
    answer it. When the supervisor of the sessions crashes, all the
    sessions end at once and the tasks that run do not stop with their
    session: they end at the end of the tool or of the ttl. A kill of
    one session has the same effect.
  * The tasks of a stdio session end with the connection, in the same
    way.

The option `max_tasks_per_session` limits the tasks of one session
that run at the same time (default `100`). The option
`max_tasks_per_principal` limits the tasks of one principal in all its
sessions (default `1000`). Only the tasks in the status
`working` or `input_required` count: a task in a terminal status does
not. A task-augmented `tools/call` that would pass the limit gets the
JSON-RPC error `-32000 "too many tasks"` and no task is created.

The options `max_task_records_per_owner` (default `1000`) and
`max_task_bytes_per_owner` (default 64 MiB) limit the records of one
owner, not only the tasks that run. All the records of the owner count:
active and terminal. A record is not removed before its TTL. A client
that reaches the record limit waits for the TTL of its records, or it
asks a shorter `ttl` in the next create, so that the records go away
earlier. The byte limit is soft: the size of the result of a task is
not known before the task ends, so the results of the tasks that were
active at the check can pass it.

The check and the start are not one step: two creates at the same time
can pass a limit by one. The owner is the principal, or the session on
a server with no authorization. On an open server the worst case of the
node is `max_sessions` times the record limits of one owner. To lower
it, lower `max_sessions`, `task_max_ttl_ms` or the record limits.

A limit refuses a task with the JSON-RPC error `-32000 "too many tasks"`.
The error is not a failure of the server. The field `data.limit` has the
name of the option that refused the task:

| `data.limit` | Meaning | What the client can do |
|---|---|---|
| `max_tasks_per_session` | The session has too many tasks that run. | Wait for a task to end, or cancel one and try again. |
| `max_tasks_per_principal` | The principal has too many tasks that run in all its sessions. | Same as above. |
| `max_task_records_per_owner` | The owner has too many task records, active and terminal. | Wait for the TTL of the old records, or ask a shorter `ttl` in the next creates. |
| `max_task_bytes_per_owner` | The task records of the owner are too big. | Same as above. |

A task made for bad input is a task and the record limits count it.

The check of the limit reads a counter that the index keeps for each
session and each principal: the creation of a task does not scan the
records of the other tasks. The default index of the facade
OzMcp.Tasks.Records changes the counters around each write and each
delete of the store: the counters of the active tasks and the counts
of the records and of the bytes of each owner. A store that owns its
index keeps the counters itself.

The scopes of the tool are part of the record of a task. A request for
`tasks/get`, `tasks/result`, `tasks/cancel` or `tasks/list` checks them
against the principal of the request (see the guide about the
authorization).
