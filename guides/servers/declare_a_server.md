# Declare a server

This guide describes each block of a server module. A server module
declares one MCP server: its information, its capabilities and the
modules of its tools, resources, templates and prompts.

For a first procedure with one tool and one server, read the
introduction guide.

## What a server module is

A server module is a module with `use OzMcp.Config.Server`. One module
declares one MCP server. The client sends `initialize` and the server
answers with one `InitializeResult`: the protocol version, the server
information, the capabilities, the instructions and the root `_meta`.

The registry blocks of the module give the entity modules. The methods
`tools/list`, `resources/list`, `resources/templates/list` and
`prompts/list` read these modules. The methods `tools/call`,
`resources/read` and `prompts/get` call the callback of the entity
module. The framework selects the module with the name, the uri, or the
uri template of the request.

The DSL checks the declaration at compile time. A wrong block stops the
compilation with an error. The runtime checks the rest at boot. For
example, the boot fails when two tool modules of one server declare the
same tool name.

Two rules apply to the whole module:

  * The module imports the root macros only. A nested macro, for example `name/1`, does not work at the root of the module.
  * You declare each root block one time only. A block that you declare two times stops the compilation.

## A short example

```elixir
defmodule MyApp.MarketingServer do
  use OzMcp.Config.Server

  server_info do
    name "marketing-server"
    version "1.0.0"
  end

  tools do
    tool MyApp.Tools.WeatherTool
  end

  resources do
    resource MyApp.Resources.CompanyResource
  end
end
```

This module is complete. The `server_info` block is required and one
registry block at least is required. The blocks `tools` and `resources`
declare the capabilities `tools` and `resources` automatically. The
module names in the blocks point to the entity modules of the entity
guides.

## A long example

The long example shows each block. The helper `MyApp.Workspace` stands
for the store of the roots in a real application. The module names of
the entities and of the verifier come from the other guides.

```elixir
defmodule MyApp.Workspace do
  @moduledoc false

  # A fake. A real application stores the roots of a session here.
  def put_roots(_session_id, _roots), do: :ok
end
```

```elixir
defmodule MyApp.EngineeringServer do
  use OzMcp.Config.Server

  protocol_version "2025-11-25"

  instructions """
  Use the tools to read the tickets of a team.
  Read the resources for the definitions of the project.
  """

  server_info do
    name "engineering-server"
    version "1.0.0"
    title "Engineering Server"
    description "MCP server of the engineering team"
    website_url "https://engineering.example.com"

    icon do
      src "https://assets.example.com/engineering-light.png"
      mime_type "image/png"
      sizes ["48x48", "96x96"]
      theme "light"
    end

    icon do
      src "https://assets.example.com/engineering-dark.png"
      mime_type "image/png"
      sizes ["48x48"]
      theme "dark"
    end
  end

  capabilities do
    resources do
      subscribe true
    end

    logging %{}
    completions %{}
    experimental %{"example.com/preview" => %{enabled: true}}

    tasks do
      list %{}
      cancel %{}
      requests %{tools: %{call: %{}}}
    end
  end

  tools do
    paginate 20

    list_result do
      meta "catalog", "engineering"
      extra "x-catalog-version", "3"
    end

    tool MyApp.Tools.TeamReportTool
    tool MyApp.Tools.WeatherTool
  end

  resources do
    paginate 50
    resource MyApp.Resources.EngineeringResource
  end

  templates do
    paginate 15
    template MyApp.Templates.EngineeringTemplate
  end

  prompts do
    prompt MyApp.Prompts.EngineeringPrompt
  end

  authorization do
    verifier MyApp.AuthVerifier
    authorization_servers ["https://auth.example.com"]
    scopes_supported ["reports:read", "admin"]
    challenge_scopes ["reports:read"]
    filter_by_scope true
    resource_name "Engineering MCP"
    resource_documentation "https://engineering.example.com/docs/mcp"
  end

  meta "team", "engineering"
  extra "x-build", "2026.10"

  @impl true
  def roots_list_changed(ctx) do
    case OzMcp.Client.list_roots(ctx) do
      {:ok, roots} -> MyApp.Workspace.put_roots(ctx.session_id, roots)
      {:error, _reason} -> :ok
    end
  end
end
```

The next sections describe each block of this example.

## The blocks

This table gives the reference of each macro. The guides of the entities
give the macros of the entity modules.

| Macro | Block | Value | Wire field |
|---|---|---|---|
| `protocol_version` | root | `"2025-11-25"` (the only value and the default) | `protocolVersion` |
| `instructions` | root | non-empty string | `instructions` |
| `name`, `version` | `server_info` | non-empty string, required | `serverInfo.name`, `serverInfo.version` |
| `title`, `description`, `website_url` | `server_info` | non-empty string | `serverInfo.title`, `serverInfo.description`, `serverInfo.websiteUrl` |
| `src` | `icon` | `https:` URL, `http:` URL of a loopback host, or `data:` URI. Required | `serverInfo.icons[].src` |
| `mime_type` | `icon` | non-empty string | `serverInfo.icons[].mimeType` |
| `sizes` | `icon` | list of `"any"` and `"WxH"` strings | `serverInfo.icons[].sizes` |
| `theme` | `icon` | `"light"` or `"dark"` | `serverInfo.icons[].theme` |
| `resources` | `capabilities` | block with the flag below | `capabilities.resources` |
| `subscribe` | `capabilities > resources` | boolean (`false` gives no field) | `capabilities.resources.subscribe` |
| `logging`, `completions` | `capabilities` | the empty map `%{}` | `capabilities.logging`, `capabilities.completions` |
| `experimental` | `capabilities` | non-empty map, string or atom keys | `capabilities.experimental` |
| `list`, `cancel`, `requests` | `capabilities > tasks` | map, each optional | `capabilities.tasks.list`, `capabilities.tasks.cancel`, `capabilities.tasks.requests` |
| `tool`, `resource`, `template`, `prompt` | registry block | module, one time only | none |
| `paginate` | registry block | integer 1 or more | `nextCursor` of the list result |
| `meta`, `extra` | root or `list_result` | key: string or atom; value: JSON term | `_meta` of the result; a field of the result |
| `verifier` | `authorization` | module, required | none |
| `authorization_servers` | `authorization` | non-empty list of https URLs, required | none |
| `scopes_supported`, `challenge_scopes` | `authorization` | list of scope tokens | none |
| `filter_by_scope` | `authorization` | boolean (default `true`) | none |
| `resource_name`, `resource_documentation` | `authorization` | string; the second is an http(s) URL | none |

### protocol_version and instructions

`protocol_version` sets the protocol version of the `initialize`
answer. The value `"2025-11-25"` is the only supported value and the
default. You can omit the block.

`instructions` gives text that the client shows to the model before the
model calls the tools. The value is a non-empty string. The block is
optional and you declare it at the root of the module one time only.

### server_info

The `server_info` block is required and you declare it one time only.
`name` and `version` are required. `title`, `description` and
`website_url` are optional. Each value is a non-empty string.

The `icon` block is optional and you can declare it more than one
time. `src` is required. `mime_type` and `sizes` are optional and you
declare each one one time in its `icon` block. `theme` takes the value
`"light"` or `"dark"`.

The `src` of an icon must be an `https:` URL with a host, an `http:` URL
of a loopback host (`localhost`, `127.0.0.1` or `::1`), or a `data:` URI.
Each entry of `sizes` is `"any"` or a `"WxH"` string with two positive
integers, for example `"48x48"`. A value outside these rules stops the
compilation.

The icons of the server go to `serverInfo.icons` in the `initialize`
answer.

### capabilities

The `capabilities` block is optional and you declare it one time only.
Write the block only for the flags of this list:

  * `subscribe true` in `resources`: the clients can send `resources/subscribe` and `resources/unsubscribe`.
  * `logging %{}`: the clients can send `logging/setLevel`. The value
    is the empty map: a map with a key stops the compilation.
  * `completions %{}`: the clients can send `completion/complete`. The
    value is the empty map: a map with a key stops the compilation.
    The boot also checks the `complete/4` callbacks of the modules
    (see the completions guide).
  * `experimental`: a non-empty map. The keys are names of strings or atoms. An empty map stops the compilation.
  * `tasks`: the block of the task capabilities. `list`, `cancel` and `requests` are optional maps. `requests %{tools: %{call: %{}}}` says that a client can run `tools/call` as a task.

Without the related flag, the method of the flag gives a method-not-found
error to the client. For example, a client that sends `completion/complete`
to a server with no `completions` capability gets an error.

### The registry blocks

The blocks `tools`, `resources`, `templates` and `prompts` list the
entity modules of the server. You declare each block at the root of the
module one time only and each block needs one entry at least:

  * `tool MyApp.Tools.WeatherTool` in `tools`.
  * `resource MyApp.Resources.CompanyResource` in `resources`.
  * `template MyApp.Templates.EngineeringTemplate` in `templates`.
  * `prompt MyApp.Prompts.EngineeringPrompt` in `prompts`.

You list each module one time in its block. The framework reads the
entities of all the modules in the order of the block.

`paginate 20` sets the size of a page of the list method of the block.
The value is an integer of 1 or more and you declare it one time per
block. Without `paginate`, the list method returns all the entities at
each call and never gives a `nextCursor`. A request with a `cursor`
then gets the error `-32602`, because the server gave no cursor. A
`cursor` with the value `null` is the same as no `cursor`.

The `nextCursor` of a page is an opaque string: the client sends it back
as it is and the server refuses a cursor that it did not give, or that
names a page after the last page, with the error `-32602`.

The `list_result` block is optional and you declare it one time per
registry block. It needs one `meta` or one `extra` at least. `meta` puts
a key in the `_meta` object of the list result. `extra` puts a field at
the top level of the list result. For example, the `list_result` of the
`tools` block of the long example gives:

```json
{"tools": [...], "x-catalog-version": "3",
 "_meta": {"catalog": "engineering"}}
```

An `extra` key with a reserved name stops the compilation. The reserved
keys are `_meta` and `nextCursor` and the name of the list, for example
`tools`. At the root, the reserved keys are `_meta`, `protocolVersion`,
`capabilities`, `serverInfo` and `instructions`.

### meta and extra

`meta` and `extra` work at the root of the module and inside each
`list_result` block. At the root, `meta` fills the `_meta` object of the
`initialize` answer and `extra` puts a field at the top level of the
answer.

The key is a string, or an atom that becomes a string. The keys `nil`,
`true` and `false` are refused. The key of a `meta` entry must be a
`_meta` key of the specification: an optional prefix (labels with dots,
ended by `/`) and a name. The prefixes whose second label is
`modelcontextprotocol` or `mcp` are reserved: the library writes them,
not your code. The key of an `extra` entry is a name of a field of the
answer: no format rule applies to it and the reserved names of the
section above are refused. The value is a JSON term. `true`, `false`
and `nil` stay as they are. Another atom becomes a string. You declare
each key one time per block.

### authorization

The `authorization` block declares that the server is protected and
how. A server with no block is open. The block is optional and you
declare it one time only:

  * `verifier` (required): a module with the `OzMcp.Auth` behaviour.
  * `authorization_servers` (required): the URLs of the authorization servers that can issue a token. The scheme is `https`. `http` is allowed only for a loopback host.
  * `scopes_supported`: the scopes that the server knows. Without the key, the metadata document gives the union of the `required_scopes` of the entity modules.
  * `challenge_scopes`: the scopes in the `WWW-Authenticate` header of a `401` or a `403` when the verifier gives none of its own.
  * `filter_by_scope` (default `true`): with `false`, the list methods return every entity and the calls alone obey the scopes.
  * `resource_name` and `resource_documentation`: two optional fields of the metadata document.

With this block, the runtime requires the option `resource_url` for the
server and refuses to boot without it. The URL of the endpoint is not
part of the block. A release can read it from the environment. The
guide about authorization gives the full procedure.

## Validation rules

The DSL checks the values of this table at compile time. A value outside
its rule stops the compilation with an error. The table gives the place
of each rule and the rules that the runtime checks again at run time:

| Value | Rule | Where it is checked |
|---|---|---|
| tool `name` | 1 to 128 characters of `A-Za-z0-9_.-` | compile: a warning, or an error with `strict_names?: true` of `use OzMcp.Config.Tool` |
| root of `input_schema` and `output_schema` of a tool | JSON Schema with the type `"object"` at the root | compile; the build of a `%Tool{}` struct at boot for a module with `dsl?: false` |
| `uri` of a resource | absolute URI with a scheme, for example `file:///logs/app.log` | compile; the build of a `%Resource{}` struct at boot |
| `last_modified` of an `annotations` block | ISO 8601 date and time with an offset, for example `2025-01-12T15:00:58Z` | compile; the build of the annotations at run time |
| icon `src` | an `https:` URL with a host, an `http:` URL of a loopback host (`localhost`, `127.0.0.1`, `::1`), or a `data:` URI | compile; the build of an `%Icon{}` struct at run time |
| icon `sizes` | each entry is `"any"` or a `"WxH"` string with two positive integers, for example `"48x48"` | compile; the build of an `%Icon{}` struct at run time |
| `logging` in `capabilities` | the empty map `%{}` | compile |
| `completions` in `capabilities` | the empty map `%{}` | compile; the boot also refuses the capability with no `complete/4` in a prompt, template or resource module and warns for the reverse |
| key of a `meta` block | a `_meta` key of the specification: an optional prefix (labels with dots, ended by `/`) and a name; the prefixes whose second label is `modelcontextprotocol` or `mcp` are reserved | compile |
The entity guides give the details of each rule. The framework turns a
map entry of a module with `dsl?: false` into a struct and checks it as a
struct, see
[Entity modules](../entities/overview.md#way-2-the-entries-of-list-0). The
boot also refuses an entry with a term that is not JSON.

The runtime also checks each result of a callback: the rules of the
entity guides and the `structuredContent` of a tool against its
`outputSchema`. The runtime options `check_results` and
`check_output_schemas` turn parts of this check off. The guide about the
runtime options gives what each one turns off and what stays on.

## The automatic capabilities

The capabilities `tools`, `resources` and `prompts` come from the
registry blocks. The server never announces `listChanged`: the lists are
read one time at boot.

  * A registry block gives the capability `%{}`. The short example declares `tools` and `resources` this way. The flag `subscribe` in `capabilities > resources` adds `subscribe: true` to the capability `resources`.
  * A `resources` block in `capabilities` with no `resources` or `templates` registry block stops the compilation. The error says the registry block that you must add.

The `templates` block has no capability of its own. The capability
`resources` covers the templates and the resources.

## The roots_list_changed callback

A client that declared the `roots` capability can send
`notifications/roots/list_changed`: its list of roots changed. Override
`roots_list_changed/1` in the server module to react. The default does
nothing.

The framework runs the callback in its own process, after the
notification is accepted. The result is ignored and a failure is only
logged. There is no request, so there is no response stream for the
calls of `OzMcp.Client`. A call needs an open `GET` stream of the
session and gives `{:error, :no_stream}` without it. The option
`wait_for_stream: true` queues the request for the next stream.

The runs are bounded. At most one run per session runs at a time. A
burst of notifications that arrives during a run gives one more run
after it. A run stops at the `request_timeout_ms` of the server, or after
5 minutes without the option. Do not count the notifications. Read the
roots with `OzMcp.Client.list_roots/2` in the callback.

## The generated functions

The DSL generates the functions of this table. The application does not
implement them. `<kind>` is `tools`, `resources`, `templates` or
`prompts`.

| Function | Result |
|---|---|
| `config/0` | the full configuration of the server |
| `initialize_result/0` | the `InitializeResult` of the `initialize` answer |
| `authorization/0` | the map of the `authorization` block, or `nil` |
| `paginate_<kind>/0` | the `paginate` value of the block, or `nil` |
| `list_<kind>_result_meta/0` | the `_meta` map of the `list_result` block, or `nil` |
| `list_<kind>_result_extras/0` | the `extra` map of the `list_result` block, or `nil` |

The two functions of the `list_result` have long names for the
templates: `list_resource_templates_result_meta/0` and
`list_resource_templates_result_extras/0`.

A block that you do not declare generates the default functions too:
`paginate_tools/0` returns `nil`. Your code can call the functions of a
kind before you add the block of the kind.

## Two servers in one application

One application can run more than one server. Each server module
declares its own entities. The example application of this project runs
two servers: `MyApp.MarketingServer` and `MyApp.EngineeringServer`.

Start one `{OzMcp, ...}` child for each server module and mount
`OzMcp.Router` two times, one time per path:

```elixir
children = [
  {OzMcp, server: MyApp.MarketingServer, allowed_origins: ["http://localhost:4000"]},
  {OzMcp, server: MyApp.EngineeringServer, allowed_origins: ["http://localhost:4000"]},
  {Bandit, plug: MyApp.Router, ip: {127, 0, 0, 1}, port: 4000}
]
```

```elixir
forward "/marketing/mcp", to: OzMcp.Router,
  init_opts: [instance: MyApp.MarketingServer]

forward "/engineering/mcp", to: OzMcp.Router,
  init_opts: [instance: MyApp.EngineeringServer]
```

The option `resource_url` is per server. Give it to the child of the
server: `{OzMcp, server: MyApp.EngineeringServer, resource_url:
"https://engineering.example.com/mcp", allowed_origins: [...]}`.

## Starting servers with options setting

Each `{OzMcp, opts}` child takes the option `:server` and the options of
that server. The options that you do not give keep their default. The
keys `:server`, `:name`, `:transport` and `:allowed_origins` belong to
the instance and the other keys are the options of the table below.

The example gives options to `MyApp.MarketingServer`. The child of
`MyApp.EngineeringServer` has no other option, so this server keeps its
default options:

```elixir
children = [
  {OzMcp,
   server: MyApp.MarketingServer,
   allowed_origins: ["http://localhost:4000"],

   # Sessions
   session_timeout_ms: 600_000,
   session_init_timeout_ms: 30_000,
   session_snapshot: MyApp.Session.Snapshot,
   session_restore_miss_ttl_ms: 5_000,
   max_sessions: 1_000,
   max_sessions_per_principal: 5,
   max_streams_per_session: 4,
   max_subscriptions_per_session: 1_000,
   max_log_rate: 100,

   # Run of the callbacks
   request_timeout_ms: 30_000,
   request_cancel_grace_ms: 2_000,
   client_request_timeout_ms: 60_000,
   elicitation_timeout_ms: 300_000,
   sampling_timeout_ms: 120_000,
   client_tasks: false,
   client_task_poll_interval_ms: 2_000,
   check_results: true,
   check_output_schemas: true,

   # Requests
   allowed_hosts: :any,
   max_body_bytes: 1_048_576,

   # GET streams (SSE)
   sse_heartbeat_ms: 15_000,
   sse_retry_ms: 2_000,
   sse_max_stream_ms: 3_600_000,
   sse_event_log_size: 1_024,
   sse_event_log_bytes: 1_048_576,
   sse_event_log_session_bytes: 8_388_608,
   sse_event_log_max_streams: 256,
   sse_resume_window_ms: 300_000,

   # PubSub
   pubsub: OzMcp.PubSub.Registry,

   # Tasks
   task_store: OzMcp.Tasks.EtsStore,
   task_default_ttl_ms: 3_600_000,
   task_max_ttl_ms: 86_400_000,
   task_poll_interval_ms: 1_000,
   task_page_size: 20,
   max_tasks_per_session: 100,
   max_tasks_per_principal: 1_000,
   max_task_records_per_owner: 1_000,
   max_task_bytes_per_owner: 67_108_864,
   tasks_follow_session: true,

   # Authorization
   max_token_bytes: 16_384,

   # Telemetry
   telemetry_prefix: [:oz_mcp]},
  {OzMcp, server: MyApp.EngineeringServer, allowed_origins: ["http://localhost:4000"]},
  {Bandit, plug: MyApp.Router, ip: {127, 0, 0, 1}, port: 4000}
]
```

`MyApp.Session.Snapshot` is a module of the application. It must
implement the behaviour `OzMcp.Session.Snapshot`. Without the option,
the module is the default `OzMcp.Session.Snapshot.None`, which keeps
nothing.

The option `resource_url` is not in the example. A server with no
`authorization` block must not set it. A server with the block must set
it. The section "authorization" gives the details.

The guide about the [runtime options](../runtime/runtime_options.md) gives each option of a server entry with its default and its check at boot.

The runtime checks the value of each known option at boot. A value of
the wrong type stops the boot with an error.

## Common mistakes

  * A nested macro at the root. For example, `name "x"` outside `server_info` gives the compile error `undefined function name/1`.
  * A block that you declare two times. For example, two `server_info` blocks stop the compilation.
  * A registry block with no entry. The error is `must declare at least one tool` (or resource, template, prompt).
  * A module that you list two times in one registry block.
  * A `resources` block in `capabilities` and no `resources` or `templates` block at the root.
  * A `list_result` block with no `meta` and no `extra`. The error says to remove the block.
  * An `extra` key with a reserved name. For example, `extra "nextCursor", "1"` in a `list_result` block.
  * An empty `experimental` map.
  * `paginate 0`. The value must be 1 or more.
  * A `theme` with a value other than `"light"` or `"dark"`.
  * Two modules of one kind with the same key. For example, two tool modules with the same tool name. Each module compiles and the runtime refuses to boot.
  * An `authorization` block with no `resource_url` option in the options of the child. OzMcp refuses to boot. The same happens with a `resource_url` for a server with no `authorization` block.
  * An unknown option of the child of a server, for example a key with a typo. The boot refuses it and lists the known options.
  * One line with two faults. The DSL checks the value, then the place, then
    a second declaration and it stops at the first fault.
