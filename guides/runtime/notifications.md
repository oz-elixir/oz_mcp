# Notifications

This guide describes the notifications that a callback sends to the
client. A notification needs no answer: the process of the callback
does not wait. The messages with an answer are the requests to the
client. The guide about the requests to the client describes them.

## The notifications

Each function of `OzMcp.Notify` sends one notification to a fixed set
of sessions:

| Notification | Function | Destination |
|---|---|---|
| `notifications/message` | `OzMcp.Notify.log/4` | the stream of the request (the ctx) |
| `notifications/message` | `OzMcp.Notify.log_session/5` | the `GET` stream of one session |
| `notifications/message` | `OzMcp.Notify.broadcast_log/4` | each session of the server |
| `notifications/progress` | `OzMcp.Notify.progress/3` | the stream of the request |
| `notifications/resources/updated` | `OzMcp.Notify.resource_updated/3` | the sessions that subscribed to the URI |
| `notifications/elicitation/complete` | `OzMcp.Notify.elicitation_complete/3` | one session |

Two notifications of a task are not in the table:
`notifications/tasks/status` and the progress of a task. The functions
`OzMcp.Notify.task_status/3` and `OzMcp.Notify.task_progress/7` send
them to one session, like `elicitation_complete/3` does. The machinery
of a task does not call these two functions for its own messages: the
status and the progress of a task go to the owner of the task (the
guide about the tasks describes the route). These two functions stay
for the code that wants a message on one session. The guide about the
tasks describes them.

## Where a notification travels

`log/4` and `progress/3` write on the response stream of the `POST`
request that the callback runs for. The response becomes an event
stream (`text/event-stream`) and the client receives the notification
even when no `GET` stream is open. A request that has no stream (a
process of the application) falls back to the `GET` stream of the
session.

The ctx of a task routes the message to the owner of the task, like
the status of the task. An open `tasks/result` request for the task
receives the message on each of its streams. Without an attached
stream, every session of the owner receives the message: with
authorization the sessions of the principal, without it the session of
the task. The ctx of a task adds the related-task `_meta` to the
params. For a log, the level of each receiving session (set with
`logging/setLevel`) decides alone whether that session gets the
message.

The other functions write on one stream of each session and append
the notification to the event log of that stream. A client that
reconnects with `Last-Event-ID` receives the events of its own stream.
A notification that the server sends when no `GET` stream of the
session is open can wait for a later `GET`: the HTTP transport guide
gives the rule.

## The capabilities

The server sends each notification even when the `initialize` result
does not announce it. The capability tells the client that it can
expect the notification. Declare the capabilities in the server
module:

| Capability | The client learns |
|---|---|
| `logging %{}` | `notifications/message` exists and the client can send `logging/setLevel` |
| `subscribe true` in `resources` | the client can send `resources/subscribe` and `notifications/resources/updated` tells it when a URI changes |

```elixir
capabilities do
  logging %{}

  resources do
    subscribe true
  end
end
```

The guide about the servers describes the `capabilities` block.

`elicitation_complete/3` needs no capability of the server. It needs
the capability `elicitation.url` of the client: without it, the
function gives `{:error, :capability_not_supported}` and sends nothing.

## The level of the client

A session receives `notifications/message` only after the client set a
level with the method `logging/setLevel`. Before that, the send is a
no-op: `log/4`, `log_session/5` and `broadcast_log/4` return `:ok`
and nothing goes on the wire.

The levels are the severities of RFC 5424, from the lowest to the
highest: `:debug`, `:info`, `:notice`, `:warning`, `:error`,
`:critical`, `:alert`, `:emergency`. A session receives a message when
the level of the message is equal to or higher than the level of the
session. A client that sets `:warning` receives `:warning` and higher
and no `:info`.

The option `:logger` names the logger of the message (a string). The
client shows this name.

## The rate of log messages

Each session accepts `notifications/message` at a bounded rate. The
option `max_log_rate` (default `100`) sets the number of log
notifications that one session accepts for each second. The session
holds a token bucket that starts full: the first messages go out at
once (the burst is `max_log_rate` messages). Each message uses one
token and the bucket gets back `max_log_rate` tokens for each
second, up to the burst. At the default rate, one token comes back
each 10 ms.

A message over the rate is dropped. The caller gets `:ok`, as for a
message that the level refuses: a drop is not told to the client and
the client cannot tell the difference between "no log" and "log
dropped". All the levels share the same bucket, so a flood of `:info`
messages also drops `:error` messages. A message that the level of the
session refuses never reaches the bucket: it uses no token.

The session counts the messages that it drops and reports the count
one time each second, with the event `[:oz_mcp, :log, :dropped]` of
the telemetry and a warning in the log of the server. The report holds
the count only: no data, no level and no logger name. The guide about
the telemetry describes the event.

Set `max_log_rate: nil` to turn the limit off, for a job that sends
many logs on purpose (for example one line for each row of an import).

## The progress token

`progress/3` reports the progress of the request that the callback
runs for. The notification carries the `progressToken` of the request.
The client puts this token in the `_meta` of the request (`tools/call`,
`resources/read` and so on). A request with no `progressToken`
produces no notification: `progress/3` returns `:ok` and nothing goes
on the wire.

The ctx must hold `:instance` when it holds a `progressToken`: a ctx
with a token and no `:instance` raises `ArgumentError` and nothing
goes on the wire. The ctx that the library gives to a callback always
has it.

The `_meta` of the request must be an object and its `progressToken`
must be a string or an integer. A request whose `_meta` is not an
object, or whose `progressToken` is not a string or an integer, is
refused with the error `-32602`: the callback does not run. A request
with no `_meta` is valid. A JSON `null` for `_meta` or for
`progressToken` is the same as a missing member.

| Option | Value |
|---|---|
| `:total` | the total number of steps |
| `:message` | a text for the client |

```elixir
Notify.progress(ctx, 1, total: 3)
Notify.progress(ctx, 2, total: 3, message: "half done")
# dropped: 2 is not larger than 2
Notify.progress(ctx, 2, total: 3)
```

The `progress` value must increase with each call for the same token.
A value that is equal to or smaller than the last one is dropped: the
function returns `:ok` and the client gets nothing. A debug line is
written. The first value can be any number. A value that is not a
number is not checked.

Progress is meaningful only while the request runs. Do not call
`progress/3` after the callback returned.

## The data of a notification

The data of a notification must hold JSON terms: strings, numbers,
booleans, `nil`, lists and maps with atom or string keys. A pid, a
tuple, a reference, a function or a port is not a JSON term. A struct
is not a JSON term: convert it first. A string must be valid UTF-8. A
map must not hold the same key as an atom and as a string (`:a` and
`"a"`): the data is refused.

The log functions check the data before the send. They return
`{:error, :not_encodable}` and send nothing when the data holds a term
that JSON cannot encode. This also covers a string that is not valid
UTF-8.

The other functions encode in the `Server`. A notification that the
`Server` cannot encode is dropped. The `Server` writes one error log
with the name of the method and the type of the failure, never the
data. The sender still gets `:ok` and the server and its sessions are
not affected.

## The `_meta` of the server

`resource_updated/3` accepts the option `:_meta`, a map that goes in
the params. The keys of the map follow the `_meta` key format of the
specification (the entity guides describe the rule): a key with a
reserved prefix, or a key outside the format, gives
`{:error, :invalid_meta}` and nothing goes on the wire. The `list_*`
functions raise `ArgumentError` for such a key, because their params
go through a struct.

## A message for every session

WARNING: without the option `:principal`, `broadcast_log/4` sends the
message to every initialized session of the server, thus to every
tenant. Do not put the data of one client in this message. Two ways
keep the data of one client private:

* Send about one request with `log/4` and the ctx of the request.
* Send to one principal with the option `:principal`: an
  `OzMcp.Auth.Principal`, or a key `{issuer, subject}`. The message
  goes only to the sessions of that principal.

```elixir
Notify.broadcast_log(MyApp.McpServer, :warning, "maintenance in 10 minutes")

Notify.broadcast_log(MyApp.McpServer, :info, %{build: "2026.10"},
  principal: {nil, "alice"}, logger: "deploy")
```

## Many nodes

The default module, `OzMcp.PubSub.Registry`, keeps the subscribers in a
`Registry` of the local node. A notification therefore reaches the
sessions of the node that sends it only.

A cluster needs `pubsub: OzMcp.PubSub.PG` in the child spec:

```elixir
{OzMcp, server: MyApp.McpServer, pubsub: OzMcp.PubSub.PG}
```

`OzMcp.PubSub.PG` uses `:pg`. A notification reaches the sessions of
every connected node that runs the same instance. The delivery is "at
most once": there is no acknowledgement and no order between two
senders. The host must connect the nodes. The guide
[Run many nodes](cluster.md) gives the full deployment
model.

## Example

The tool of this example imports the rows of a CSV text. It reports
each row with `progress/3`, writes one summary with `log/4` and tells
the sessions that the list of resources changed:

```elixir
defmodule MyApp.Tools.ImportTool do
  use OzMcp.Config.Tool

  alias OzMcp.Notify

  tool "import_users" do
    title "Import users"
    description "Import the users of a CSV text"

    input_schema %{
      type: "object",
      properties: %{csv: %{type: "string"}},
      required: ["csv"]
    }
  end

  @impl true
  def call(ctx, %{"name" => "import_users", "arguments" => %{"csv" => csv}}) do
    rows = String.split(csv, "\n", trim: true)
    total = length(rows)

    rows
    |> Enum.with_index(1)
    |> Enum.each(fn {_row, index} ->
      Notify.progress(ctx, index, total: total)
    end)

    Notify.log(ctx, :info, %{imported: total})

    {:ok, %{content: [%{type: "text", text: "#{total} users imported"}]}}
  end
end
```

The client receives `notifications/progress` only when it put a
`progressToken` in the `_meta` of the `tools/call` request.
`notifications/message` reaches the client only after it sent
`logging/setLevel`.
