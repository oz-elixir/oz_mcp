# OzMcp

[![CI](https://github.com/oz-elixir/oz_mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/oz-elixir/oz_mcp/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/oz_mcp.svg)](https://hex.pm/packages/oz_mcp)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://oz-mcp.hexdocs.pm)
[![License](https://img.shields.io/hexpm/l/oz_mcp.svg)](https://github.com/oz-elixir/oz_mcp/blob/main/LICENSE)

OzMcp is an Elixir framework to write MCP servers.
It provides a rich DSL to declare servers, tools, resources and prompts in plain modules.
Currently the framework supports only the full MCP specification,
revision [2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25).  
The implementation is checked in CI by the official MCP conformance tool
and the official TypeScript SDK client.  
_(See [CONFORMANCE.md](https://oz-mcp.hexdocs.pm/conformance.html) for an overview of what is implemented, feature by feature.)_

The API can change before version 1.0.

## Features

### The protocol

  * **Server features**: tools, resources, resource templates, prompts
    and completions, with resource subscriptions and paginated lists.
  * **Tools**: input and output JSON Schemas compiled at boot, input
    checked before the callback runs, `structuredContent` checked
    against the output schema, annotations and icons.
  * **Utilities**: log messages with the level of the client, progress
    notifications, request cancellation and ping.
  * **Requests to the client**: sampling with tools, elicitation in the
    form and the URL modes and roots, sent from any callback.
  * **Tasks in both directions** (experimental, off by default): a
    `tools/call` that answers at once with a task, for a tool that sets
    `task_support` and requests that run as tasks of the client, with
    the runtime option `client_tasks: true`.
  * **Two transports, the same answers**: Streamable HTTP with SSE
    streams and resume through `Last-Event-ID` and stdio through
    `mix oz_mcp.stdio`.
  * **Authorization**: an OAuth 2.1 resource server, with the Protected
    Resource Metadata document, sessions bound to their principal,
    scopes for each entity, lists filtered by scope and the end of the
    sessions of a principal.

### Declare, do not wire

  * **A DSL or plain data**: declare each entity with a DSL checked at
    compile time, or return structs and maps from `list/0`.
  * **Capabilities from the declarations**: the server announces what
    its modules declare.
  * **A guard around user code**: a raise in a callback gives the error
    `-32603` to the client, never a lost request.
  * **Many servers in one application**, each on its own path.

### Built for production

  * **More than 40 runtime options** for each server: timeouts, limits,
    SSE streams, tasks, checks of the results, sessions and
    authorization, readable from the environment of a release.
  * **Limits** on sessions, sessions of a principal, streams,
    subscriptions, the log rate, tasks, the request body and the token
    size.
  * **Browser safety**: an allow list of the browser origins (the boot
    refuses `"*"`) and an allow list of the hosts against DNS
    rebinding.
  * **Telemetry**: spans for the requests, the callbacks, the sessions,
    the tasks and the requests to the client and events for the auth
    refusals, the limits and the snapshots.
  * **Many nodes**: broadcasts across the cluster through `:pg`
    (`OzMcp.PubSub.PG`), a guide for sticky routing on `Mcp-Session-Id`
    and failover of the sessions through a snapshot store.
  * **Bandit or Cowboy** as the HTTP server.
  * **Conformance measured in CI** by the official MCP conformance tool
    and the official TypeScript SDK client.
  * **Testing helpers** (`OzMcp.Testing`) to test a server, its tools,
    resources, templates and prompts.

## What OzMcp does not do

  * **No list changes at run time**: the server reads its modules at
    boot and never announces `listChanged`. A change of a module needs
    a restart of the instance.
  * **One revision of the protocol**: `2025-11-25` only.
  * **Tasks can change**: the tasks are experimental in the protocol
    and they can change or go away before 1.0.

## Installation

OzMcp needs Elixir `~> 1.19`.

Add `oz_mcp` and an HTTP server to the dependencies of your
application:

```elixir
def deps do
  [
    {:oz_mcp, "~> 0.9.1"},
    {:bandit, "~> 1.15"}
  ]
end
```

Then run `mix deps.get`.

To follow the development version, use the git repository instead:

```elixir
{:oz_mcp, github: "oz-elixir/oz_mcp", branch: "main"}
```

Bandit is the HTTP server of the examples. Cowboy, through
`plug_cowboy`, is supported too: the HTTP transport guide gives its
mount options.

## Quick start

Write a tool module:

```elixir
defmodule MyApp.Tools.EchoTool do
  use OzMcp.Config.Tool

  tool "echo" do
    title "Echo"
    description "Send back the text"

    input_schema %{
      type: "object",
      properties: %{text: %{type: "string"}},
      required: ["text"]
    }
  end

  @impl true
  def call(_ctx, %{"name" => "echo", "arguments" => %{"text" => text}}) do
    {:ok, %{content: [%{type: "text", text: text}]}}
  end
end
```

Write a server module that declares the tool:

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

Start the server and the HTTP server in the application supervisor.
Put `OzMcp` before Bandit in the list of the children. A request that
arrives before the server starts gets `503`. The list
`allowed_origins` names the origins of the browsers that can call the
server. The boot refuses `"*"`. The list `allowed_hosts` names the
hosts that the server accepts in the `Host` header: it stops the DNS
rebinding attacks on a local server.

```elixir
children = [
  {OzMcp,
   server: MyApp.McpServer,
   allowed_origins: ["http://localhost:4000"],
   allowed_hosts: ["localhost", "127.0.0.1"]},
  {Bandit, plug: MyApp.Router, ip: {127, 0, 0, 1}, port: 4000}
]
```

Mount the server in your plug router:

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

Send an `initialize` request with `curl`:

```shell
curl -i http://localhost:4000/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        "protocolVersion":"2025-11-25","capabilities":{},
        "clientInfo":{"name":"curl","version":"1.0"}}}'
```

The response has an `mcp-session-id` header. Send this header with each
next request. Send `notifications/initialized` before the first
`tools/list`.

## Run on stdio

For a local client, run the server on stdin and stdout:

```shell
mix oz_mcp.stdio MyApp.McpServer
```

stdout carries the JSON-RPC messages only. The logs and the messages of
Mix go to stderr. Give `--start-app` to start the host application
before the server starts. See `Mix.Tasks.OzMcp.Stdio` for the options
and for the client configuration.

## Guides

The guides go from an empty Mix project to a server that runs and
they give each option of the entities and of the runtime. Read them
on [HexDocs](https://oz-mcp.hexdocs.pm).

  * [Getting started](https://oz-mcp.hexdocs.pm/getting_started.html): from an
    empty Mix project to the first `tools/list` response.
  * [Declare a server](https://oz-mcp.hexdocs.pm/declare_a_server.html): the blocks
    of a server module and the automatic capabilities.
  * [Entity modules](https://oz-mcp.hexdocs.pm/overview.html): the rules that the
    four kinds of entity share.
  * Each kind of entity: [Tools](https://oz-mcp.hexdocs.pm/tools.html),
    [Resources](https://oz-mcp.hexdocs.pm/resources.html),
    [Templates](https://oz-mcp.hexdocs.pm/templates.html),
    [Prompts](https://oz-mcp.hexdocs.pm/prompts.html) and
    [Completions](https://oz-mcp.hexdocs.pm/completions.html).
  * [Runtime options](https://oz-mcp.hexdocs.pm/runtime_options.html): each option
    of a server and the configuration of a release.
  * [HTTP transport](https://oz-mcp.hexdocs.pm/http_transport.html): the mount, the
    streams and the resume, the limits and Cowboy.
  * [stdio transport](https://oz-mcp.hexdocs.pm/stdio_transport.html): the Mix task
    and the client configuration.
  * [Authorization](https://oz-mcp.hexdocs.pm/authorization.html): the verifier, the
    metadata document and the scopes.
  * [Tasks](https://oz-mcp.hexdocs.pm/tasks.html): a `tools/call` that runs in the
    background.
  * [Run many nodes](https://oz-mcp.hexdocs.pm/cluster.html): broadcasts, sticky
    routing, failover and the rolling deploy.
  * [Requests to the client](https://oz-mcp.hexdocs.pm/client_requests.html):
    sampling, elicitation and roots.
  * [Notifications](https://oz-mcp.hexdocs.pm/notifications.html): logs, progress
    and the broadcasts.
  * [Telemetry](https://oz-mcp.hexdocs.pm/telemetry.html): the events and their
    metadata.
  * [Testing](https://oz-mcp.hexdocs.pm/testing.html): test the tools, prompts
    and resources of a server with `OzMcp.Testing`.
  * Long examples: [Tool examples](https://oz-mcp.hexdocs.pm/tool_examples.html),
    [Resource examples](https://oz-mcp.hexdocs.pm/resource_examples.html),
    [Template examples](https://oz-mcp.hexdocs.pm/template_examples.html),
    [Prompt examples](https://oz-mcp.hexdocs.pm/prompt_examples.html).

## Contributing

The commands of the checks, the rules of the tests and the conformance
tool are in [CONTRIBUTING.md](https://oz-mcp.hexdocs.pm/contributing.html).

## License

OzMcp is released under the MIT License, see [LICENSE](https://oz-mcp.hexdocs.pm/license.html). To
report a security problem, see [SECURITY.md](https://oz-mcp.hexdocs.pm/security.html).

## Authors

Designed and initially written by hand by [@odelbos](https://github.com/odelbos), who remains the maintainer.

Later work was done in collaboration with AI models under the maintainer's supervision.

| Model (reasoning effort) | Role |
|---|---|
| Claude Opus 5.5 (high / medium) | Codebase reviews, plans, tasks and implementation reviews. |
| Claude Sonnet 5.5 (high / medium) | Plans and implementation of complex tasks. |
| DeepSeek V4.1 Flash (high) | Implementation of complex and medium tasks. |
| GLM 5.3 Flash (high) | Implementation of medium and simple tasks. |