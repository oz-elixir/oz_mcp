# Getting started

This guide gives one procedure: from an empty Mix project to the first
`tools/list` response. The procedure makes one server with one tool. The
server runs on the Streamable HTTP transport.

## Requirements

You need this software:

  * Elixir `~> 1.19`. Run `elixir --version` to read the version.
  * Bandit or Cowboy, an HTTP server. This guide runs the server on
    Bandit.
  * `curl` in a terminal. You can use another HTTP client.

## Create the project

Create a project with a supervision tree:

```shell
mix new my_app --sup
```

The examples of this guide use the project name `my_app`. Use another name
if you want.

## Add the dependencies

Add `oz_mcp` and an HTTP server to the `deps` function in `mix.exs`.
The examples use Bandit. Cowboy, through `plug_cowboy`, is supported
too: the HTTP transport guide gives its mount options.

```elixir
defp deps do
  [
    {:oz_mcp, "~> 0.9.1"},
    {:bandit, "~> 1.15"}
  ]
end
```

Before 1.0, a minor release can change the API, so the requirement
accepts the patch releases of 0.9 only. Then run:

```shell
mix deps.get
```

## Write a tool

A tool is a function that the model of the client can call. Make the folder
`lib/my_app/tools`. Write the file `lib/my_app/tools/echo_tool.ex`:

```elixir
defmodule MyApp.Tools.EchoTool do
  use OzMcp.Config.Tool

  tool "echo" do
    title "Echo"
    description "Send back the text"

    input_schema %{
      type: "object",
      properties: %{text: %{type: "string", minLength: 1}},
      required: ["text"]
    }
  end

  @impl true
  def call(_ctx, %{"name" => "echo", "arguments" => %{"text" => text}}) do
    {:ok, %{content: [%{type: "text", text: text}]}}
  end
end
```

The `tool` block declares one tool with a name, a title, a description
and a JSON Schema for the arguments. The DSL checks the schema at compile
time. The `call/2` callback runs the tool. The first argument is the
context `ctx` of the request. The second argument holds the name and the
arguments of the call, with string keys.

## Write a server

A server module declares one MCP server: its information and its tools.
Write the file `lib/my_app/mcp_server.ex`:

```elixir
defmodule MyApp.McpServer do
  use OzMcp.Config.Server

  server_info do
    name "my-app"
    version "1.0.0"
  end

  tools do
    tool MyApp.Tools.EchoTool
  end
end
```

The `server_info` block gives the name and the version of the server. The
client reads them in the `initialize` response. The `tools` block lists
the tool modules of the server.

## Write the router

`OzMcp.Router` is a plug. You mount it at a path in your plug router.
Write the file `lib/my_app/router.ex`:

```elixir
defmodule MyApp.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  forward "/mcp", to: OzMcp.Router, init_opts: [instance: MyApp.McpServer]

  match _ do
    send_resp(conn, 404, "not found")
  end
end
```

Each request to the path `/mcp` goes to `OzMcp.Router`. The `instance`
option names the instance of your server module.

## Start the runtime and the HTTP server

`OzMcp` starts one supervised instance for each server module.
Bandit starts the HTTP server. Bandit calls your router for each request.

Replace the `start/2` function in `lib/my_app/application.ex`:

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {OzMcp,
       server: MyApp.McpServer,
       allowed_origins: ["http://localhost:4000"],
       allowed_hosts: ["localhost", "127.0.0.1"]},
      {Bandit, plug: MyApp.Router, ip: {127, 0, 0, 1}, port: 4000}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
```

On Cowboy instead of Bandit:

```elixir
{Plug.Cowboy, scheme: :http, plug: MyApp.Router, ip: {127, 0, 0, 1},
  port: 4000,
  protocol_options: [idle_timeout: 300_000, reset_idle_timeout_on_send: true]}
```

The order of the children is important. `OzMcp` starts before the
HTTP server. A request that arrives before the server starts gets the
status `503`.

The `allowed_origins` list gives the origins of the browsers that can call
the server. OzMcp compares each origin as a string. It refuses the
value `"*"` at boot. The `allowed_hosts` list gives the host names that
the server accepts in the `Host` header.

> **CAUTION:** Bind the HTTP server to `127.0.0.1`, as in the example. A
> server on all the network interfaces accepts connections from your local
> network. A page in a browser can send requests to the server with DNS
> rebinding. The `allowed_hosts` list stops these requests: see the section
> "DNS rebinding" of the [HTTP transport](../runtime/http_transport.md#dns-rebinding)
> guide.

Start the server:

```shell
mix run --no-halt
```

The server is available at `http://127.0.0.1:4000/mcp`.

## Send the first requests with curl

An MCP session has three steps:

1. `initialize`: the client and the server agree on the protocol version
   and the capabilities. The response has an `mcp-session-id` header.
2. `notifications/initialized`: the client tells the server that it is
   ready. The server answers with the status `202`.
3. The requests of the session, for example `tools/list`.

Send the `mcp-session-id` header with each request after `initialize`.

Open a terminal. Send `initialize`:

```shell
curl -i http://127.0.0.1:4000/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        "protocolVersion":"2025-11-25","capabilities":{},
        "clientInfo":{"name":"curl","version":"1.0"}}}'
```

Copy the value of the `mcp-session-id` header of the response. Put it in a
variable:

```shell
SESSION="paste the value of the mcp-session-id header here"
```

Send `notifications/initialized`:

```shell
curl -i http://127.0.0.1:4000/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -H "mcp-session-id: $SESSION" \
  -H 'mcp-protocol-version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
```

Send `tools/list`. The response lists the `echo` tool:

```shell
curl http://127.0.0.1:4000/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -H "mcp-session-id: $SESSION" \
  -H 'mcp-protocol-version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

## Connect an MCP client

The MCP Inspector is a program to examine an MCP server. Run it:

```shell
npx @modelcontextprotocol/inspector
```

The Inspector opens a web page. In the web page:

1. Set the transport type to `Streamable HTTP`.
2. Set the URL to `http://127.0.0.1:4000/mcp`.
3. Press `Connect`.

The Inspector shows the tools of your server. You can call the `echo` tool
from the web page.

You can also add the server to the configuration of an MCP client. The
entry has the type `HTTP` or `URL` and the URL
`http://127.0.0.1:4000/mcp`. The format of the configuration is different
for each client.

## Format the DSL

The calls of the DSL do not use parentheses. Tell the code formatter about
the macros. Add `:oz_mcp` to the `import_deps` list in the file
`.formatter.exs` of your project:

```elixir
[
  import_deps: [:oz_mcp, :plug],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

Then run `mix format`. The formatter keeps the calls of the DSL without
parentheses, for example `tool "echo" do`.

## Next steps

Read the documentation on [HexDocs](https://hexdocs.pm/oz_mcp). It has
the reference of each module and the guides. Start with the modules
`OzMcp.Config.Server` and `OzMcp.Config.Tool`.

To test your server, see the guide [Testing](../development/testing.md).

The guides cover these subjects:

  * The declaration of a server and its capabilities.
  * Tools, resources, resource templates, prompts and completions.
  * The runtime options and the two transports, HTTP and stdio.
  * Authorization, tasks, the requests to the client and the
    notifications.
