# Tools

This guide describes each way to declare a tool module and each option
of the tool DSL. The tool is the entity that the model calls most. The
introduction guide shows a first tool and a first server.

## What a tool is

A tool is a function that the model of the client can call. The methods
`tools/list` and `tools/call` use the tools of a server. `tools/list`
gives the descriptions and the input schemas. `tools/call` runs one tool
with the arguments of the client.

A tool module is a module with `use OzMcp.Config.Tool`. One module can
declare one tool or more. The `call/2` callback of the module runs each
call, in a supervised process of its own.

## The two ways

A tool module that runs `call/2` uses `use OzMcp.Config.Tool` (DSL) or
`use OzMcp.Config.Tool, dsl?: false` (data). The rules of the two ways
and of the registration are in [Entity modules](overview.md#the-two-ways).

## Way 1: the DSL

The DSL of a tool checks the declaration at compile time. A wrong
value stops the compilation with an error.

### A short example

```elixir
defmodule MyApp.Tools.WeatherTool do
  use OzMcp.Config.Tool

  tool "get_weather" do
    title "Weather Information Provider"
    description "Get current weather information for a specific city"

    input_schema %{
      type: "object",
      properties: %{location: %{type: "string", minLength: 1}},
      required: ["location"]
    }
  end

  @impl true
  def call(_ctx, %{"name" => "get_weather", "arguments" => %{"location" => location}}) do
    {:ok, %{content: [%{type: "text", text: "Weather in #{location} is 24°C"}]}}
  end
end
```

The `tool` block declares one tool. `title` and `description` are
optional. A tool without a `title` or without a `description` gives a
message at compile time. `input_schema` gives the JSON Schema of the
arguments. The DSL checks the schema at compile time.

The page [Tool examples](../long_examples/tool_examples.md#the-dsl) has
a long example that uses each macro of the DSL.

### The macros

`use OzMcp.Config.Tool` imports the root macro `tool/2` only. The other
macros work only inside their block. A macro outside its block stops the
compilation.

| Macro | Block | Value | Wire field |
|---|---|---|---|
| `tool "name"` | root | 1 to 128 characters of `A-Za-z0-9_.-`, unique in the module | `name` |
| `title` | `tool`, `annotations` | non-empty string | `title` |
| `description` | `tool` | non-empty string | `description` |
| `required_scopes` | `tool` | list of scope tokens | none (a `403` and a filtered `tools/list`) |
| `input_schema` | `tool` | JSON Schema map, not empty. The root must have the type `"object"` (default `{"type":"object","properties":{}}`) | `inputSchema` |
| `output_schema` | `tool` | JSON Schema map, not empty. The root must have the type `"object"` | `outputSchema` |
| `annotations` | `tool` | block, one time | `annotations` |
| `title` | `annotations` | non-empty string | `annotations.title` |
| `read_only_hint`, `destructive_hint`, `idempotent_hint`, `open_world_hint` | `annotations` | boolean | `annotations.readOnlyHint`, `annotations.destructiveHint`, `annotations.idempotentHint`, `annotations.openWorldHint` |
| `execution` | `tool` | block, one time | `execution` |
| `task_support` | `execution` | `"forbidden"`, `"optional"` or `"required"` | `execution.taskSupport` |
| `poll_interval` | `execution` | positive integer (ms), one time | none (the `pollInterval` hint of the task records of the tool) |
| `immediate_response` | `execution` | non-empty string, one time | none (the `io.modelcontextprotocol/model-immediate-response` text of the `CreateTaskResult`) |
| `icon` | `tool` | block, repeatable | one entry of `icons` |
| `src` | `icon` | `https:` URL, `http:` URL of a loopback host, or `data:` URI. Required | `icons[].src` |
| `mime_type` | `icon` | non-empty string | `icons[].mimeType` |
| `sizes` | `icon` | list of `"any"` and `"WxH"` strings | `icons[].sizes` |
| `theme` | `icon` | `"light"` or `"dark"` | `icons[].theme` |
| `meta key, value` | `tool` | key: string or atom; value: a JSON term. Each key one time | `_meta.<key>` |

The rules of the `icon` block and of the key of `meta` are in
[Entity modules](overview.md#icons-and-_meta).

`required_scopes ["reports:read"]` protects the tool. A `tools/call`
without all the scopes gets the status `403`. `tools/list` hides the
tool from a principal that lacks the scopes. The guide about
authorization gives the details.

`task_support "optional"` says that the client can run the tool as a
task. `task_support "required"` says that the client must run it as a
task: on a server with the capability, a plain call gets the error
`-32601`.

A server runs a tool as a task only when the `tasks` capability has
`requests.tools.call`. Without it, the server removes the `task` member
and runs a plain call (also for `"required"`), but `tools/list` still
shows the `taskSupport` value of the tool. At boot, the server finds
this case for each tool of a module and writes one warning for
each tool. With `strict_tasks?: true`, the boot stops with an
`ArgumentError`. With `warn?: false`, the boot writes nothing.

`poll_interval 5000` gives the `pollInterval` hint (ms) of the task
records of the tool. The client reads it as the interval between two
polls of `tasks/get`. A tool that runs as a task can declare it, so it
needs a `task_support` of `"optional"` or `"required"` in the same
block. The value never goes out in `tools/list`: the option
`task_poll_interval_ms` of the server is the hint of the tools that give
none.

`immediate_response "Export started. It can take a few minutes."` sets
the `io.modelcontextprotocol/model-immediate-response` key of the
`_meta` of the `CreateTaskResult` of the tool. The client can show the
text to the model before the task ends. The value never goes out in
`tools/list`. Like `poll_interval`, it needs a `task_support` of
`"optional"` or `"required"` in the same block.

The DSL generates the function `list/0`. The module cannot define it.

### The `use` options

The options `dsl?:` and `warn?:` are in
[Entity modules](overview.md#the-use-options).

| Option | Default | Effect |
|---|---|---|
| `strict_names?:` | `false` | `true` stops the compilation (a DSL module) or the boot (a `dsl?: false` module) for a tool name outside the rule of the table above. `false` gives a warning only (a compiler warning, or a log warning at boot) |
| `strict_tasks?:` | `false` | `true` stops the boot for a tool with `task_support "optional"` or `"required"` on a server that has no `tasks.requests.tools.call` capability. `false` gives a warning in the log. `warn?: false` removes the warning |

### Tool names

The name of a tool follows the recommendation of the MCP specification:
1 to 128 characters of `A-Za-z0-9_.-`. A name outside this rule gives a
compiler warning. Some clients refuse a tool with such a name, or change
the name.

To enforce the rule, use `use OzMcp.Config.Tool, strict_names?: true`.
The compilation then stops with an error for a name outside the rule. To
remove the warning, use `use OzMcp.Config.Tool, warn?: false`.

The rule covers both kinds of module. A module with `dsl?: false` gives
its names in `list/0`, so the check runs at boot: a name outside the rule
gives a warning in the log, `strict_names?: true` stops the boot with an
`ArgumentError` and `warn?: false` removes the warning.

## Way 2: data

A tool module with `dsl?: false` writes its `list/0` function. Each
entry is a `%OzMcp.Structs.Tool{}` struct, or a map with the wire keys (`name`,
`inputSchema`, ...). The rules of the entries are in
[Entity modules](overview.md#way-2-the-entries-of-list-0). The rules of
the tool only:

  * A nested unknown key, inside `execution`, `annotations` or `icons`,
    is an error that names the path. A custom value goes in `_meta`.
  * The `taskSupport` of a map is the string `"forbidden"`, `"optional"`
    or `"required"`, or the atom. The runtime holds the atom.

### A short example

The two examples below declare the same tool.

The struct form:

```elixir
defmodule MyApp.Tools.StructWeatherTool do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.{CallToolResult, TextContent, Tool}

  @impl true
  def list do
    [
      %Tool{}
      |> Tool.name("get_weather")
      |> Tool.title("Weather Information Provider")
      |> Tool.description("Get current weather information for a specific city")
      |> Tool.input_schema(%{
        type: "object",
        properties: %{location: %{type: "string", minLength: 1}},
        required: ["location"]
      })
    ]
  end

  @impl true
  def call(_ctx, %{"name" => "get_weather", "arguments" => %{"location" => location}}) do
    result =
      %CallToolResult{}
      |> CallToolResult.content([
        %TextContent{} |> TextContent.text("Weather in #{location} is 24°C")
      ])
      |> CallToolResult.build()

    {:ok, result}
  end
end
```

The map form:

```elixir
defmodule MyApp.Tools.MapWeatherTool do
  use OzMcp.Config.Tool, dsl?: false

  @tools [
    %{
      name: "get_weather",
      title: "Weather Information Provider",
      description: "Get current weather information for a specific city",
      inputSchema: %{
        type: "object",
        properties: %{location: %{type: "string", minLength: 1}},
        required: ["location"]
      }
    }
  ]

  @impl true
  def list, do: @tools

  @impl true
  def call(_ctx, %{"name" => "get_weather", "arguments" => %{"location" => location}}) do
    {:ok, %{content: [%{type: "text", text: "Weather in #{location} is 24°C"}]}}
  end
end
```

The page [Tool examples](../long_examples/tool_examples.md#way-2-data)
has a long example of one tool in its two forms, with the nested values.

Each function of the struct modules builds the wire value of its field.
Read the documentation of `OzMcp.Structs.Tool` for the full list. The
map uses the wire keys of the MCP specification: `inputSchema`,
`outputSchema`, `readOnlyHint`, `taskSupport`. The keys of the map go to
the client as they are; the rules above give the exceptions.

The framework does not check the schemas at compile time. The framework
checks each `inputSchema` and `outputSchema` at the boot of the
instance and it compiles each schema there: the root must have the type
`"object"`. A tool with an invalid schema stops the boot and the
error names the tool, the module and the kind of schema. The build of a
`%Tool{}` struct checks the root at the boot too: a struct with
`inputSchema: nil`, or with a wrong root, stops the boot; a struct with
the default empty map gets the default object schema. A request does
not compile a schema.

## The callback

The `call/2` callback runs each `tools/call`:

```elixir
@impl true
def call(ctx, params)
```

  * `ctx` is the context of the `tools/call` request. Read `OzMcp.Context` for the
    keys of the map, for example `ctx.session_id` and
    `ctx.client_capabilities`.
  * `params` is the full `params` object of the request. `params["name"]`
    is the name of the tool. `params["arguments"]` is the map of the
    arguments, with string keys. Use `Map.get(params, "arguments", %{})`
    for a tool whose schema has no required property.

The input schema of the tool checked the arguments before the call. The
check gave the default values of the schema to the arguments that the
client did not send.

A JSON `null` for an optional member of the request is the same as a
missing member. For example, `"arguments": null` gives the same
`params` as a call with no `arguments`.

The return values:

  * `{:ok, result}`: `result` is a tool result map, or the wire map of a
    `%OzMcp.Structs.CallToolResult{}`. The result must carry the
    `content` member. Set `isError: true` for a failure
    that the model can correct. The model reads the `content` of the
    result.
  * `{:error, %OzMcp.Utils.Error{}}`: a protocol error. The client
    receives the `code`, the `message` and the `data` of the error in
    the JSON-RPC `error` object. The model does not read this error.
    `OzMcp.Utils.Error.invalid_params/2` and
    `OzMcp.Utils.Error.internal_error/2` build it with the right code.

Each other return value gives the client the error `-32603`. A result
also follows a shape rule:

  * `content` is a list of content blocks. A content block is a struct,
    or a map with a `type` member. The value of `type` is a non-empty
    string, or an atom (for example `:text`) that the encoder writes as
    a string. A block whose `type` names a block of the specification
    (`text`, `image`, `audio`, `resource_link`, `resource`) is checked
    with the rules of that block: a `text` block needs a `text`, an
    `image` and an `audio` block need a `data` and a `mimeType`, a
    `resource_link` block needs a `uri` and a `name` and a `resource`
    block needs a `resource` map with a `uri` and a `text` or a `blob`.
    A block with another `type` needs the `type` only; the block goes to
    the client as it is.
  * `isError`, when present, is a boolean.
  * `structuredContent`, when present, is a map.

A `{:ok, result}` that does not follow the rule (an empty map, a plain
string, a `content` that is not a list, a content block map with no
`type`) gives the error `-32603` too. The rule accepts atom keys and
string keys. The framework builds a plain map result into its result
struct first, so a map and a struct get the same check (see
[Entity modules](overview.md#the-result-of-a-callback-struct-or-map)).
A member that is present must have a valid value. The rule is the same
for a plain call and for a task: a task tool that returns such a result
makes a `failed` task with the status message `internal error` and a
`tasks/result` request for it gives the error `-32603`. The guide about
the tasks gives the details.

A result with a string that is not valid UTF-8 gives the error `-32603`
and a log line with the path of the string. A task tool that returns
such a result makes a `failed` task.

The framework checks the keys of the top-level `_meta` of a plain map
result, with the same rule as the `meta` block of the DSL: a key
outside the `_meta` key format of the specification, or with a reserved
prefix, gives the error `-32603` to the client and an error in the
server log. A task tool that returns such a result makes a `failed`
task. The keys that the framework itself writes stay valid. A `_meta`
under a map inside the result is not checked, with one exception: a
content block whose `type` names a block of the specification is built
like the block struct, so its `_meta` gets the same check.

Rules around the callback:

  * The callback runs in a supervised process of its own, not in the request process. Do not use the process dictionary of the request.
  * An input that does not agree with the `inputSchema` gives a result with `isError: true` and the messages of the violations. The callback does not run.
  * A tool with an `outputSchema` must return a `structuredContent` that agrees with it. Another result gives the error `-32603` to the client. A result with `isError: true` is not checked. A plain map whose `structuredContent` is not an object is refused by the shape rule first: the client gets `-32603` with the message `internal error`. The runtime option `check_output_schemas` of the instance turns this check off; the guide about the runtime options gives the details.
  * The option `request_timeout_ms` of the server gives the deadline of the run. After the deadline, the process stops and the client receives the error `-32603`.
  * Use `OzMcp.Notify.progress/3` to report the progress of a long call. Use `OzMcp.Client.elicit/3` or another request to the client when the call needs the input of the user. Read the guide about the requests to the client.
  * Each run of the callback gives one span to the telemetry of the library. The guide about telemetry describes its events.

The framework can stop the callback. The transport registers the request in
its session before the handler runs and `notifications/cancelled` asks the
session to cancel it: the session sends `{:oz_mcp_cancel, request_id, reason}`
to the process that waits for the result, which stops the callback. The id is
compared strictly (`1` and `"1"` are different), so a session never cancels
the request of another session. A cancel for a request that is finished or
unknown is ignored.

A stopping callback first receives the exit signal
`{:shutdown, {:cancelled, reason}}`. A callback that does not trap exits stops
at once. A callback that traps exits receives the signal as a message, can
release its resources and is killed when `request_cancel_grace_ms` elapses.
The same two steps stop a callback at its deadline and when its session ends.
If the callback finishes while it is stopped, its result wins. Otherwise the
caller receives the error `-32800`, which the client ignores because it
dropped the request. The callback never outlives the process that waits for
it. A task is cancelled with `tasks/cancel`, not with
`notifications/cancelled`.

The result of the callback must contain only JSON terms: `nil`, booleans,
numbers, atoms, strings, lists and maps with atom or string keys. A struct
is not a JSON term, including `DateTime`, `Date`, `Time`, `NaiveDateTime` and
`URI`: convert these values before you return them (for example
`DateTime.to_iso8601(dt)`). Another term gives the client the error `-32603`
and the server log gives the path of the invalid term.

## Register the tool module in a server

Register a tool module in the `tools` block of the server. See [The registry blocks](../servers/declare_a_server.md#the-registry-blocks).

## Common mistakes

  * Two tools with the same name in one module. The compilation stops.
  * Two tools with the same name in two modules of one server. Each module compiles and the runtime refuses to boot.
  * An `execution` block without `task_support`. The `tools/list` method fails when the framework builds the tool.
  * `task_support "required"` in a server without the `tasks` capability. Each call gets the error `-32601`.
  * A result without `structuredContent` for a tool with an `outputSchema`. The client receives the error `-32603`.
  * A different schema from `list/0` at a later time in a module.
    The server reads the list at boot
    and the catalog keeps the schema of that start. A stop and a start
    of the instance reads the new schema.
