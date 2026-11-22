# Testing

`OzMcp.Testing` is a client for the tests of your server. It starts one
instance of the server under the supervisor of the test and drives the
real HTTP path in-process: `OzMcp.Router` runs through `Plug.Test`.
Every stage runs as in production: the validation of the JSON-RPC
message, the authorization, the scopes, the session, the input and
output schemas and the guard of the callback. A direct call of the
callback skips these stages.

## Start a client

The examples build a server with one tool. Write the tool:

```elixir
defmodule MyApp.Tools.ForecastTool do
  use OzMcp.Config.Tool

  tool "weather" do
    title "Weather"
    description "Give the weather of a city"

    input_schema %{
      type: "object",
      properties: %{city: %{type: "string", minLength: 1}},
      required: ["city"]
    }
  end

  @impl true
  def call(_ctx, %{"name" => "weather", "arguments" => %{"city" => _city}}) do
    {:ok, %{content: [%{type: "text", text: "Sunny"}]}}
  end
end
```

Write the server:

```elixir
defmodule MyApp.ForecastServer do
  use OzMcp.Config.Server

  server_info do
    name "weather"
    version "1.0.0"
  end

  tools do
    tool MyApp.Tools.ForecastTool
  end
end
```

Write the test. The client starts in `setup`. `start/2` starts one
instance under the supervisor of the test, then the client process,
then it sends `initialize`:

```elixir
defmodule MyApp.ForecastServerTest do
  use ExUnit.Case, async: true

  alias OzMcp.Testing

  setup do
    assert {:ok, client} = Testing.start(MyApp.ForecastServer)
    %{client: client}
  end

  test "gives the weather", %{client: client} do
    assert {:ok, %{"content" => [%{"text" => "Sunny"}]}} =
             Testing.call_tool(client, "weather", %{"city" => "Paris"})
  end
end
```

The instance has a unique name, so each test has its own server and
`async: true` works. The instance and the client stop at the end of
the test. `stop/1` ends the session before the end of the test: it
stops the calls that still run, and each of them gives
`{:error, %{"code" => -32603}}`.

`start/2` gives `{:ok, client}` or `{:error, error}`. The error is the
JSON-RPC error of a refused `initialize` (see "Test a protected
server"). The options of the client are `:token`, `:capabilities`,
`:handle`, `:client_info` and `:timeout` (milliseconds, default
`5000`). Every other option goes to the instance as it is, for example
`session_timeout_ms` or `max_sessions`. The option `allowed_origins`
defaults to `[]`.

`initialize_result/1` gives the result of `initialize`, with string
keys. A test reads the server info, the capabilities, the instructions
and the `_meta` of the server from it:

```elixir
%{"serverInfo" => %{"name" => "weather"}, "capabilities" => %{"tools" => _}} =
  OzMcp.Testing.initialize_result(client)
```

`start/2` needs a test process: it calls
`ExUnit.Callbacks.start_supervised!/1`. It refuses the instance option
`sse_max_stream_ms` with an `ArgumentError` (see "The limits").

## Call the entities

Each kind of entity has a function. The function builds the params and
sends the request:

| Function | Method |
|---|---|
| `call_tool/4` | `tools/call` |
| `get_prompt/4` | `prompts/get` |
| `read_resource/3` | `resources/read` |
| `complete/4` | `completion/complete` |
| `list/3` | `tools/list`, `prompts/list`, `resources/list` or `resources/templates/list` |
| `request/4` | any request |

A tool gives its result:

```elixir
{:ok, %{"content" => [%{"type" => "text", "text" => "Sunny"}]}} =
  OzMcp.Testing.call_tool(client, "weather", %{"city" => "Paris"})
```

A tool error is a result with `isError`. The framework maps an input
that does not match the input schema to this result:

```elixir
# The tool has a required argument "city".
{:ok, %{"isError" => true, "content" => [%{"text" => _message}]}} =
  OzMcp.Testing.call_tool(client, "weather", %{})
```

A protocol error is `{:error, error}`. The error is the JSON-RPC error
of the server, with string keys:

```elixir
# No tool has the name "nope". The code is -32602.
{:error, %{"code" => -32602, "message" => _message}} =
  OzMcp.Testing.call_tool(client, "nope")

# No resource has this URI. The code is -32002.
{:error, %{"code" => -32002}} =
  OzMcp.Testing.read_resource(client, "file:///unknown.md")
```

The other functions give the result of their method:

```elixir
{:ok, %{"messages" => messages}} =
  OzMcp.Testing.get_prompt(client, "code_review", %{"language" => "elixir"})

{:ok, %{"contents" => [%{"uri" => uri, "text" => text}]}} =
  OzMcp.Testing.read_resource(client, "file:///acme.md")

{:ok, %{"completion" => %{"values" => values}}} =
  OzMcp.Testing.complete(client, %{"type" => "ref/prompt", "name" => "code_review"},
    %{"name" => "language", "value" => "e"}
  )

{:ok, %{"tools" => tools}} = OzMcp.Testing.list(client, :tools)
{:ok, %{"tools" => tools, "nextCursor" => cursor}} =
  OzMcp.Testing.list(client, :tools, cursor: cursor)
```

The kinds of `list/3` are `:tools`, `:prompts`, `:resources` and
`:resource_templates`. The option `:cursor` continues a paginated
list.

`request/4` sends any other request, for example `ping` or
`logging/setLevel`:

```elixir
{:ok, %{}} = OzMcp.Testing.request(client, "ping")
{:ok, _result} = OzMcp.Testing.request(client, "logging/setLevel", %{"level" => "debug"})
```

`notify/3` sends a notification and gives `:ok` when the server
accepts it:

```elixir
:ok = OzMcp.Testing.notify(client, "notifications/cancelled", %{"requestId" => 7})
```

Each call takes three options. `:meta` is the `_meta` of the request,
for example the progress token. `:id` is the JSON-RPC id, a counter of
the client by default; an `:id` that a pending call of the client
already uses gives `{:error, %{"code" => -32603}}`, and the counter
skips the ids that a pending call uses. `:timeout` is the time of the
answer in milliseconds, the `:timeout` of `start/2` by default. A
request that gives no answer in that time gives
`{:error, %{"code" => -32603}}`.

## Read the notifications

The client sends each notification of the server to the test process
as `{:oz_mcp_notification, method, params}`. `assert_receive` reads
it.

A callback writes progress only when the request has a progress
token. Give it in `:meta`. For example, a tool `import` that reports
the items that it read:

```elixir
test "reports the progress", %{client: client} do
  assert {:ok, _result} =
           Testing.call_tool(client, "import", %{"path" => "tickets.csv"},
             meta: %{"progressToken" => 1}
           )

  assert_receive {:oz_mcp_notification, "notifications/progress",
                  %{"progress" => _progress, "progressToken" => 1}}
end
```

A log reaches the client after it set a level with `logging/setLevel`.
The callback calls `OzMcp.Notify.log(ctx, level, data)`, or
`OzMcp.Notify.log_session/5` writes on the `GET` stream of a session.
For example, the tool `import` logs `OzMcp.Notify.log(ctx, :info, "imported")`:

```elixir
{:ok, _result} = OzMcp.Testing.request(client, "logging/setLevel", %{"level" => "info"})
{:ok, _result} = OzMcp.Testing.call_tool(client, "import", %{"path" => "tickets.csv"})

assert_receive {:oz_mcp_notification, "notifications/message",
                %{"level" => "info", "data" => "imported"}}
```

A resource update goes to the sessions that subscribed to the URI. The
function `instance/1` gives the name of the instance for
`OzMcp.Notify`:

```elixir
uri = "file:///acme.md"
{:ok, _result} = OzMcp.Testing.request(client, "resources/subscribe", %{"uri" => uri})
OzMcp.Notify.resource_updated(OzMcp.Testing.instance(client), uri)

assert_receive {:oz_mcp_notification, "notifications/resources/updated", %{"uri" => ^uri}}
```

The server must declare the capabilities that the client reads:
`logging %{}` and `subscribe true` in the `resources` block (the guide
about the notifications describes them).

## Answer the requests of the server

A callback can send a request to the client: sampling, elicitation or
roots. The client declares the capability in `:capabilities` and
answers each request with `:handle`, a function of the method and the
params:

```elixir
handle = fn "sampling/createMessage", _params ->
  {:ok,
   %{
     "role" => "assistant",
     "content" => %{"type" => "text", "text" => "Sunny"},
     "model" => "test-model"
   }}
end

{:ok, client} =
  OzMcp.Testing.start(MyApp.McpServer,
    capabilities: %{"sampling" => %{}},
    handle: handle
  )
```

The capabilities are the map of `initialize`, sent as it is. They are
not derived from `:handle`: the same function can answer several
methods and the capabilities have members such as `sampling.tools`.

The function `:handle` gives `{:ok, result}` or `{:error, error}`. The
server hands the result or the error to the callback that waits for
it. Three rules give the answer of a function that fails:

  * No `:handle`, or no clause of the function for the method: the
    callback gets the error `-32601` (method not found).
  * The function raises, throws, exits or gives another value: the
    callback gets the error `-32603` (internal error). The client stays
    alive.
  * A `FunctionClauseError` raised inside the function, not by the
    function itself, is also `-32603`: it is a bug of the test, not a
    method that the test does not handle.

The client answers the `ping` of the server with `%{}` and never
calls `:handle`. A method whose capability is absent is not sent: the
callback gets `{:error, :capability_not_supported}` (the guide about
the requests to the client describes the capability of each method).

## Test a protected server

A server with an `authorization` block is reached with `:token`. The
client sends `Authorization: Bearer <token>` and the verifier of the
server runs, as in production. No option overrides the verifier.

Write a verifier for the tests. It knows one fixed token and gives the
audience of the server:

```elixir
defmodule MyApp.TestingVerifier do
  @behaviour OzMcp.Auth

  alias OzMcp.Auth.Principal

  @impl true
  def authenticate(conn, _server) do
    case OzMcp.Auth.bearer_token(conn) do
      {:ok, "test-token"} ->
        {:ok,
         Principal.new!(
           subject: "alice",
           scopes: ["secret:read"],
           audiences: ["http://localhost/mcp"]
         )}

      _other ->
        {:error, :invalid_token}
    end
  end
end
```

Write the tool and the protected server. The verifier replaces the real
one:

```elixir
defmodule MyApp.Tools.SecretTool do
  use OzMcp.Config.Tool

  tool "secret" do
    title "Secret"
    description "Give the secret"
    required_scopes(["secret:read"])
  end

  @impl true
  def call(_ctx, %{"name" => "secret"}) do
    {:ok, %{content: [%{type: "text", text: "42"}]}}
  end
end
```

```elixir
defmodule MyApp.SecretServer do
  use OzMcp.Config.Server

  server_info do
    name "secret"
    version "1.0.0"
  end

  tools do
    tool MyApp.Tools.SecretTool
  end

  authorization do
    verifier(MyApp.TestingVerifier)
    authorization_servers(["https://auth.example.com"])
    scopes_supported(["secret:read"])
  end
end
```

The test gives the token. A refused `initialize` is the other answer
of `start/2`:

```elixir
defmodule MyApp.SecretServerTest do
  use ExUnit.Case, async: true

  alias OzMcp.Testing

  test "calls a protected tool" do
    assert {:ok, client} = Testing.start(MyApp.SecretServer, token: "test-token")

    assert {:ok, %{"content" => [%{"text" => "42"}]}} =
             Testing.call_tool(client, "secret")
  end

  test "gives the error of a refused initialize" do
    assert {:error, %{"code" => -32010}} =
             Testing.start(MyApp.SecretServer, token: "wrong-token")
  end
end
```

A protected server needs an option `resource_url` and the principal
needs the same value in its audiences, or the gate gives `401`. When
`start/2` gets no `resource_url`, it sets `http://localhost/mcp`: the
default that the test verifier above gives. Give `resource_url:` to
use the URL of production, and give the same value in the audiences of
the test verifier.

## The limits

  * Every refusal is `{:error, error}`, with the JSON-RPC error of the
    body. The HTTP status and the headers are not given. A test of the
    HTTP layer itself, for example a `WWW-Authenticate` header, calls
    `OzMcp.Router` with `Plug.Test` directly.
  * `start/2` refuses the option `sse_max_stream_ms` with an
    `ArgumentError`. With the option a stream can close before its
    answer, and the client of `OzMcp.Testing` does not resume a
    stream.
  * A notification outside a request (a resource update, a log of the
    session) that the server sends before the `GET` stream of the client
    is open waits for that stream for `sse_resume_window_ms`. With
    `sse_resume_window_ms: 0` the server drops it, so a test that sets
    this option can miss the first notifications.
  * The test process gets the notifications only, never the answers of
    the server that a call returns. The messages carry no client: with
    two clients in one test, assert on the content (the URI of the
    resource, the session of a log).
  * The client runs in a test process only. It is not a client for an
    application or for a script.
