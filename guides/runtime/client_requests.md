# Requests to the client

This guide describes the requests that a callback sends to the client
while it runs. A request has an answer: the process of the callback
waits for it. The messages that need no answer are the notifications
(the guide about the notifications describes them). The same requests
from a task are in the guide about the tasks.

## What the requests are

| Method | Function | Answer |
|---|---|---|
| `elicitation/create` | `OzMcp.Client.elicit/3` | the input of the user |
| `sampling/createMessage` | `OzMcp.Client.sample/3` | a completion of the model of the client |
| `roots/list` | `OzMcp.Client.list_roots/2` | the roots of the client |
| `ping` | `OzMcp.Outbound.ping/2` | an empty result |

The functions of `OzMcp.Client` build on `OzMcp.Outbound.request/4`.
Each function blocks the calling process until the client answers, the
timeout elapses, or the session ends. Call them inside a callback:
`call/2` of a tool, `read/2` of a resource, `get/2` of a prompt,
`roots_list_changed/1` of a server, or a tool that runs as a task.
Each request gives one `client_request` span of the events of
`:telemetry`: the guide about the telemetry describes it.

Use a request when the answer changes the result: an elicitation for a
value that only the user knows, a sampling for a summary with the model
of the client, the roots for the folders that the client opened and a
`ping` to test that the client is still there.

The server decodes the answer of the client.
A JSON `null` in the answer reaches your code as `nil`.

## The capability of the client

The server sends a request only when the client declared the capability
in `initialize`. The client did not declare it: nothing is sent and the
call gives `{:error, :capability_not_supported}`. Test the capability
before the call with `OzMcp.Context.client_supports?/2` and give an
answer without the request when the test is false.

| Method | Capability of the client |
|---|---|
| `ping` | none |
| `sampling/createMessage` | `sampling` |
| `elicitation/create` (form mode) | `elicitation.form`, or an empty `elicitation` object |
| `elicitation/create` (URL mode) | `elicitation.url` |
| `roots/list` | `roots` |

Some params need a member of the capability:

| Params of the call | Capability |
|---|---|
| `tools:` or `tool_choice:` | `sampling.tools` |
| `include_context:` other than `:none` | `sampling.context` |

The capability of `client_supports?/2` is an atom or a string
(`:sampling`, `"roots"`), or a list of them for a nested member
(`[:sampling, :tools]`).

## Where the request travels

The callback runs for one `POST` request, as a task, or outside a
request. The way of the request to the client depends on this:

| Who runs the callback | Way of the request |
|---|---|
| a `POST` request (`tools/call`, `resources/read`, ...) | the response of the `POST` |
| a task | the `tasks/result` stream of the task |
| no request (`roots_list_changed/1`) | the `GET` stream of the session |

A callback of a `POST` request writes the request on the response of
the same `POST`. The response becomes an event stream
(`text/event-stream`): the request of the server is an event and the
result of the callback is the last event. A callback that sends nothing
gets the plain `application/json` response. The client answers with a
second `POST` that carries the JSON-RPC response and the server hands
the answer to the process of the callback.

A message of a callback of a `POST` request (a request to the client, a
progress notification, a log notification) goes first to the stream of
that `POST` request. The specification says that a message on the `GET`
stream SHOULD have no relation to a running client request. If the
stream of the `POST` is gone (the client closed it, or it ended at
`sse_max_stream_ms`), the server sends the message on the first `GET`
stream of the session. With no live `GET` stream, the message waits in
the event log of the session for a resume. For a request to the client,
the call checks the way first: with no `POST` stream and no `GET` stream,
it gives `{:error, :no_stream}` and sends nothing, unless
`wait_for_stream: true`. A notification gets no error. The server keeps
this fallback on purpose: without it, a request that works today would
fail with `:no_stream`.

The client may answer with an error that carries no `id`, or an `id` of
null (JSON-RPC 2.0 allows this when the client lost the id of the
request). No request of the server can wait for such an answer: the
server accepts it with `202`, logs only the code of the error and hands
nothing to a callback. An answer with a result and no `id` is still a
refusal (`400`).

A client that loses the connection keeps the tool running and resumes
the stream: a `GET` with the header `Last-Event-ID: <stream id>:<n>`
sends the events of the stream after `n` and ends after the result of
the tool (the HTTP transport guide describes the resume).

A task writes its requests on the `tasks/result` streams of the task,
with the related-task `_meta`. The process of the task holds the
request: it makes the id of the request, keeps the entry until the
client answers and hands the answer to the process of the callback.
The answer goes to the task by the owner of the task and not to the
session that carries the answer: any session of the owner can answer a
request of a task. The server sends the request only on the streams
whose client declared the capability that the request needs. The task
moves to the status `input_required` while it waits and back to
`working` when no request of it waits. When no `tasks/result` request
is open, the request waits and the timeout of the method applies. The
tasks guide describes this.

`roots_list_changed/1` runs outside a request: the request goes on the
`GET` stream of the session. With no open `GET` stream, the call gives
`{:error, :no_stream}` at once and nothing is sent. The option
`wait_for_stream: true` sends the request anyway: it waits in the event
log. When no `GET` stream of the session ended in the resume window,
the first `GET` stream that opens (a fresh one, or one that reconnects
with `Last-Event-ID`) reads it. When a `GET` stream ended in the
window, the request waits in the log of that stream and only a
reconnect with its `Last-Event-ID` reads it. Before the client sent
`notifications/initialized`, the `GET` stream does not exist: the call
gives `{:error, :session_not_initialized}`.

## Elicitation, form mode

`OzMcp.Client.elicit/3` asks the user for input. With a schema, the
client shows a form: the message and the fields of the schema. The
schema is an `OzMcp.Structs.ElicitationSchema` struct, or a map that is
already a flat schema. The form is flat: a property is a string, a
number, an integer, a boolean, or an array of strings. A nested object
raises `ArgumentError`.

```elixir
defmodule MyApp.Reports do
  @moduledoc false

  def report(_name, _team), do: "2 events today, 1 meeting"
end
```

```elixir
defmodule MyApp.Tools.ReportTool do
  use OzMcp.Config.Tool

  alias OzMcp.Client
  alias OzMcp.Structs.{ElicitationSchema, EnumSchema, StringSchema}

  tool "daily_report" do
    title "Daily report"
    description "Write the report of a person after the user gave the names"
  end

  @impl true
  def call(ctx, %{"name" => "daily_report"}) do
    schema =
      %ElicitationSchema{}
      |> ElicitationSchema.property("name", %StringSchema{} |> StringSchema.title("Name"))
      |> ElicitationSchema.property(
        "team",
        %EnumSchema{}
        |> EnumSchema.title("Team")
        |> EnumSchema.options(["core", "web", "mobile"])
      )
      |> ElicitationSchema.required(["name"])

    case Client.elicit(ctx, schema, message: "Who reads the report?") do
      {:ok, %{action: :accept, content: content}} ->
        name = Map.get(content, "name", "user")
        team = Map.get(content, "team", "core")
        {:ok, %{content: [%{type: "text", text: MyApp.Reports.report(name, team)}]}}

      {:ok, %{action: :decline}} ->
        {:ok, %{content: [%{type: "text", text: "The user declined"}], isError: true}}

      {:ok, %{action: :cancel}} ->
        {:ok, %{content: [%{type: "text", text: "The user closed the form"}], isError: true}}

      {:error, reason} ->
        {:ok,
         %{content: [%{type: "text", text: "No report: #{inspect(reason)}"}], isError: true}}
    end
  end
end
```

The result of an accepted form carries the values with string keys:

| Result | Meaning |
|---|---|
| `{:ok, %{action: :accept, content: content}}` | the user filled the form. `content` is the map of the values, with string keys |
| `{:ok, %{action: :decline, content: nil}}` | the user refused to give the data |
| `{:ok, %{action: :cancel, content: nil}}` | the user closed the form without an answer |

The server validates the content of an accepted form against the
schema. A value that does not match gives
`{:error, {:invalid_content, messages}}`. The option `validate: false`
turns the validation off.

The defaults of the schema are not added to the content: the client
prefills the form with them, but a field that the client leaves out is
not in the content. Read an optional field with `Map.get/3`.

The two messages on the wire:

```json
{"jsonrpc": "2.0", "id": 7, "method": "elicitation/create",
 "params": {"mode": "form", "message": "Who reads the report?",
            "requestedSchema": {"type": "object",
                                "properties": {"name": {"type": "string", "title": "Name"}},
                                "required": ["name"]}}}
```

```json
{"jsonrpc": "2.0", "id": 7,
 "result": {"action": "accept", "content": {"name": "Ada", "team": "core"}}}
```

## Elicitation, URL mode

`elicit/3` with a URL string is a URL interaction: the client shows the
message and sends the user to the page. The data of the page never
passes through the client. Use this mode for credentials and
authorizations.

```elixir
{:ok, %{action: action, elicitation_id: id}} =
  Client.elicit(ctx, "https://calendar.example.com/connect",
    message: "Connect your calendar account"
  )
```

The result carries the `elicitation_id` of the interaction (generated
by default, or given with the option `:elicitation_id`). The action
`:accept` means that the user agreed to open the URL. It is not the end
of the interaction.

When the interaction is done on the web site, the application tells the
client. The client can then send the request again:

```elixir
:ok = OzMcp.Notify.elicitation_complete(ctx.server, ctx.session_id, id)
```

The function `OzMcp.Notify.elicitation_complete/3` sends the
notification `notifications/elicitation/complete` with the id of the
interaction. It needs the capability `elicitation.url` of the client:
else it gives `{:error, :capability_not_supported}`. A session that
does not exist any more gives `{:error, :session_not_found}`.

A callback that cannot run before the interaction returns the error of
`OzMcp.Client.url_elicitation_required/2`. The error is the JSON-RPC
error `-32042`, with the list of the URLs. The client opens the pages
and sends the same request again when the interactions are done:

```elixir
defmodule MyApp.Calendar do
  @moduledoc false

  def connected?(_session_id), do: false
  def summary(_session_id), do: "3 events today"
end
```

```elixir
defmodule MyApp.Tools.ConnectTool do
  use OzMcp.Config.Tool

  alias OzMcp.Client

  tool "read_calendar" do
    title "Read the calendar"
    description "Read the events of the calendar of the user"
  end

  @impl true
  def call(ctx, %{"name" => "read_calendar"}) do
    if MyApp.Calendar.connected?(ctx.session_id) do
      {:ok, %{content: [%{type: "text", text: MyApp.Calendar.summary(ctx.session_id)}]}}
    else
      # The tool cannot run before the connection. The client opens the
      # page and sends the same request again when it is done.
      {:error,
       Client.url_elicitation_required([
         %{url: "https://calendar.example.com/connect", message: "Connect your calendar"}
       ])}
    end
  end
end
```

Each map of the list needs the keys `:url` and `:message` and accepts
`:elicitation_id` (generated by default).

## Sampling

`OzMcp.Client.sample/3` asks the client to complete a conversation with
its model. `messages` is a list of `OzMcp.Structs.SamplingMessage`
structs or maps. The option `max_tokens` is required.

| Option | Value |
|---|---|
| `max_tokens` | the limit of the tokens of the answer. Required |
| `system_prompt` | the text that the model reads first |
| `temperature` | a number |
| `stop_sequences` | a list of strings |
| `metadata` | a map for the vendor of the model |
| `model_preferences` | an `OzMcp.Structs.ModelPreferences` struct or a map |
| `include_context` | `:none` (the default), `:this_server` or `:all_servers` |
| `tools` | a list of `OzMcp.Structs.Tool` structs or maps |
| `tool_choice` | `:auto`, `:required`, `:none`, or an `OzMcp.Structs.ToolChoice` |
| `_meta`, `timeout`, `wait_for_stream` | see the other sections |

The example of this guide is a tool that asks the model of the client
for a summary:

```elixir
defmodule MyApp.Tools.SummaryTool do
  use OzMcp.Config.Tool

  alias OzMcp.{Client, Context}

  tool "summarize_ticket" do
    title "Summarize a ticket"
    description "Ask the model of the client for a summary of a ticket"

    input_schema %{
      type: "object",
      properties: %{text: %{type: "string", minLength: 1}},
      required: ["text"]
    }
  end

  @impl true
  def call(ctx, %{"name" => "summarize_ticket", "arguments" => %{"text" => text}}) do
    if Context.client_supports?(ctx, :sampling) do
      messages = [%{role: "user", content: %{type: "text", text: "Summarize: " <> text}}]

      case Client.sample(ctx, messages, max_tokens: 200, system_prompt: "Write one sentence.") do
        {:ok, %{content: blocks}} ->
          {:ok, %{content: blocks}}

        {:error, reason} ->
          {:ok,
           %{content: [%{type: "text", text: "No summary: #{inspect(reason)}"}], isError: true}}
      end
    else
      {:ok,
       %{content: [%{type: "text", text: "The client does not support sampling"}],
         isError: true}}
    end
  end
end
```

The result is a map with the keys `role` (`"user"` or `"assistant"`),
`content` (always a list of blocks with string keys), `model` and
`stop_reason` (`"endTurn"`, `"toolUse"`, `"maxTokens"`, or `nil`). The
content blocks are ready for the result of a tool: the example sends
them back.

A `stop_reason` of `"toolUse"` means that the model wants to run a tool:
the content holds `tool_use` blocks. Run the tools and sample again
with a `tool_result` message for each block.

The options `tools:` and `tool_choice:` need the capability
`sampling.tools` and `include_context:` other than `:none` needs
`sampling.context`. The check happens before the send: a capability
that the client did not declare gives
`{:error, :capability_not_supported}`.

## Roots

`OzMcp.Client.list_roots/2` returns the roots that the client exposes:
a list of maps with the string key `"uri"` (a `file://` URI) and the
optional key `"name"`. A server that reads files under the roots asks
for them before each read:

```elixir
case OzMcp.Client.list_roots(ctx) do
  {:ok, roots} ->
    for %{"uri" => uri} <- roots, do: watch_root(uri)

  {:error, _reason} ->
    []
end
```

`watch_root/1` is a function of the application: it keeps the roots of
the session for the reads that follow.

The client can change its roots while the session runs. A server that
wants to know it defines the callback `roots_list_changed/1` in the
server module (the guide about the servers describes the callback).
The server sends `notifications/roots/list_changed`, the framework runs
the callback and the callback asks for the roots again. The callback
runs outside a request: its requests to the client go on the `GET`
stream of the session (see the section above).

## Run a request as a task of the client

> **Experimental.** The tasks of 2025-11-25 are experimental and so is this
> feature. It is off by default. Set the runtime option `client_tasks: true`
> to use it (see the guide about the runtime options). With the option off,
> a call with `task:` gives `{:error, :client_tasks_disabled}`, sends nothing
> to the client and the server ignores `notifications/tasks/status`. The
> feature can be removed before 1.0. The gate is this: list the clients
> that the project supports and check if one declares
> `tasks.requests.sampling.createMessage` or
> `tasks.requests.elicitation.create` in its `initialize`. If none does,
> remove the feature and its docs and tests. If one does, run the client
> task e2e tests against it and decide if the feature stays experimental.

A long sampling or a long human input can run as a task of the client:
the client answers at once and the server reads the result later. Use
the option `task:` when the answer can take minutes and one open
request must not hold the connection.

`OzMcp.Client.sample/3` and `OzMcp.Client.elicit/3` run three phases
when `task:` is set:

1. The server sends the request with `params.task`. The client answers
   at once with a `CreateTaskResult` that carries a `taskId` and a
   `status`.
2. The server polls `tasks/get` at the `pollInterval` that the client
   gave, or at the interval of the options below.
3. The server reads the final result with `tasks/result` when the task
   is terminal. The result has the same shape as the result of a plain
   request. A `cancelled` task gives
   `{:error, {:client_task_cancelled, task_id}}` and the server sends
   no `tasks/result`.

A status of `input_required` means that the client has a request for
the server: the server calls `tasks/result` at once and its answer is
the final result.

| Option | Value |
|---|---|
| `task` | `true`, or `%{ttl: milliseconds}`. Needs the runtime option `client_tasks`. The `ttl` of the request defaults to the timeout of the call. The client can override it |
| `task_required` | `true`: `{:error, :capability_not_supported}` when the client cannot run the request as a task. Default `false` |
| `poll_interval` | milliseconds between two `tasks/get` calls. The `pollInterval` of the client wins, then this option, then `client_task_poll_interval_ms`. A floor of `100` ms and a ceiling of `300000` ms apply |

`OzMcp.Outbound.request_task/4` keeps a `task` value that the params
already have: the `ttl` of the `task` option applies only when the params
have no `task`.

With `client_tasks: true`, a client that did not declare the task
capability gets a plain request, so one callback works with every client.
`task_required: true` turns that fallback into
`{:error, :capability_not_supported}` and nothing is sent.

The client declares `tasks.requests.sampling.createMessage` (sampling)
or `tasks.requests.elicitation.create` (elicitation). A cancel needs
`tasks.cancel`. The cancel is best effort: when the stream is gone, or
the client did not declare it, the client task ends at its `ttl`.

The timeout of the call covers the full flow: the create, the polls and
the result. A runner deadline (`request_timeout_ms` of the tool) must be
longer than the timeout of the call, else the runner stops the callback
before the client task ends.

| Result | Meaning |
|---|---|
| `{:error, :capability_not_supported}` | `task_required: true` and the client did not declare the capability. Nothing is sent |
| `{:error, :client_tasks_disabled}` | the runtime option `client_tasks` is `false` (the default). Nothing is sent |
| `{:error, {:client_task_cancelled, task_id}}` | the client cancelled its task. No `tasks/result` is sent |
| `{:error, {:invalid_response, result}}` | the client answered a `CreateTaskResult` or a `tasks/get` with no task |
| `{:error, {:rpc_error, error}}` | the client answered with a JSON-RPC error |
| `{:error, :timeout}` | the flow ended before a terminal status. The server sends `tasks/cancel` when the client declared it |

The other errors are the errors of `OzMcp.Outbound.request/4` (see the
next sections). The calls build on `OzMcp.Outbound.request_task/4`,
which has the same options.

```elixir
case OzMcp.Client.sample(ctx, messages,
       max_tokens: 2_000,
       task: %{ttl: 600_000},
       timeout: 600_000
     ) do
  {:ok, %{content: content}} -> {:ok, summarize(content)}
  {:error, :timeout} -> {:error, "The model took too long."}
  {:error, {:client_task_cancelled, _}} -> {:error, "The client cancelled the task."}
end
```

## The timeouts

The client has a limited time to answer. The call that waits longer
gives `{:error, :timeout}` and the client receives
`notifications/cancelled` for the request. The default depends on who
answers:

| Option of a server entry | Default | Applies to |
|---|---|---|
| `elicitation_timeout_ms` | `300000` ms | `elicitation/create` |
| `sampling_timeout_ms` | `120000` ms | `sampling/createMessage` |
| `client_request_timeout_ms` | `60000` ms | `roots/list`, `ping` |

An answer of a person gets more time than an answer of a model. The
runtime options guide describes the three options. The `:timeout`
option of a call overrides the option of the server, in milliseconds or
`:infinity`:

```elixir
Client.elicit(ctx, schema, message: "Who are you?", timeout: :infinity)
```

## The errors

The errors of `OzMcp.Outbound.request/4` are the errors of each
function of this guide:

| Result | Meaning |
|---|---|
| `{:ok, result}` | the client answered with a result |
| `{:error, {:rpc_error, error}}` | the client answered with a JSON-RPC error. `error` is the map of the client (`"code"`, `"message"` and `"data"`) |
| `{:error, :timeout}` | no answer within the timeout. The client receives `notifications/cancelled` |
| `{:error, :session_terminated}` | the session ended while the callback waited. This is also the end when the session process stops for any reason (a stop can give no normal end). For a request of a task, the end of the session ends the wait only when the option `tasks_follow_session` of the server is `true` |
| `{:error, :session_not_found}` | the ctx has no live session |
| `{:error, :capability_not_supported}` | the client did not declare the capability. Nothing is sent |
| `{:error, :unsupported_method}` | the method is not a request that a server can send |
| `{:error, :not_encodable}` | the params hold a term that JSON cannot encode (a pid, a tuple, a reference, a function). Nothing is sent |
| `{:error, :no_task}` | the request is the one of a task (`ctx.task_id`) and the task does not run: it ended before the request, or it ended during the wait. When the task ended during the wait, the request reached the client: the client receives `notifications/cancelled` for it on the `tasks/result` streams of the task |
| `{:error, :no_stream}` | the request needs the `GET` stream of the session and the client has no stream open. Nothing is sent |
| `{:error, :session_not_initialized}` | the same case and the client did not send `notifications/initialized` yet. Nothing is sent |

The checks of the capability, of the params and of the route run
before the send: a request that no stream can carry fails at once and
does not wait for the timeout.

A callback that ends (a timeout of the request, a cancel, a crash)
leaves no request that waits: the client receives
`notifications/cancelled` for each request of the process and can
close the form that nobody reads.
