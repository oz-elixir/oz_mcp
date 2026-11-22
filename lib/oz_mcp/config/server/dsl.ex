#
# Helper DSL to configure server
#
defmodule OzMcp.Config.Server.DSL do
  @moduledoc """
  Compile-time macros of a server module (`use OzMcp.Config.Server`).

  The root blocks are `protocol_version/1`, `instructions/1`,
  `server_info/1`, `capabilities/1`, `tools/1`, `resources/1`,
  `templates/1`, `prompts/1`, `meta/2`, `extra/2` and `authorization/1`.
  The `capabilities/1` block holds `resources` (with `subscribe`),
  `completions`, `logging` and `tasks`. The values of `completions` and
  `logging` are the empty map `%{}`. A block declared twice raises at
  compile time and so does a property outside its block.

  A module that a `tools`, `resources`, `templates` or `prompts` block
  lists two times raises at compile time. The key of an entity (the
  `name` of a tool or of a prompt, the `uri` of a resource, the
  `uri_template` of a template) is unique in its module and in the
  server: the runtime refuses to boot when two modules of the same kind
  declare the same key.

  ## Imports

  `use OzMcp.Config.Server` imports the root macros only: the blocks of
  the list above and `meta/2` with `extra/2`. The nested macros
  (`name/1`, `title/1`, `version/1`, `list_result/1`, `icon/1`,
  `tool/1`, `paginate/1` and the others) are not imported: they work
  only inside their block. A nested macro at the root of the module
  gives a compile error (`undefined function name/1`). The server module
  can declare a local function with the name of a nested macro (for
  example `def name(text), do: text`) and call it.

  ## `meta` and `extra`

  `meta/2` and `extra/2` work at the root of the module and inside each
  `list_result` block. The key is a string, or an atom that becomes a
  string (`meta :beta, "x"` is the same as `meta "beta", "x"`). The
  keys `nil`, `true` and `false` are refused: they are values, not
  names. A key declared two times in one block raises at compile time.

  The value keeps `true`, `false` and `nil` (they become the JSON
  `true`, `false` and `null`). Another atom becomes a string
  (`meta "kind", :fast` stores `"fast"`). The other terms do not change.

  An `extra` key that names a field of the result of the block is
  refused at compile time: it would make a second JSON key with the
  same name. Use the field itself (and `meta` for `_meta`).

  | Block | Reserved `extra` keys |
  |---|---|
  | root | `_meta`, `protocolVersion`, `capabilities`, `serverInfo`, `instructions` |
  | `tools > list_result` | `_meta`, `tools`, `nextCursor` |
  | `resources > list_result` | `_meta`, `resources`, `nextCursor` |
  | `templates > list_result` | `_meta`, `resourceTemplates`, `nextCursor` |
  | `prompts > list_result` | `_meta`, `prompts`, `nextCursor` |

  ## The `authorization` block

  Declares that the server is protected and how. A server with no block
  is open: no request is refused and `authorization/0` of the server
  module returns `nil`.

      authorization do
        verifier MyApp.AuthVerifier
        authorization_servers ["https://auth.example.com"]
        scopes_supported ["files:read", "files:write"]
        challenge_scopes ["files:read"]
        filter_by_scope false
        audience_check false
        resource_name "My App MCP server"
        resource_documentation "https://docs.example.com/mcp"
      end

  * `verifier` (required) — a module that implements the `OzMcp.Auth`
    behaviour. The runtime checks the module and its `authenticate/2`
    when it starts; `authorize/3` is optional.
  * `authorization_servers` (required) — URLs of the authorization
    servers that can issue a token for this server. At least one entry,
    `https` only (`http` is accepted for a loopback host). They are
    published in the Protected Resource Metadata document
    (see `OzMcp.Auth.Metadata`).
  * `scopes_supported` — the scopes the server knows; published in the
    metadata document. Each entry must match the RFC 6749 scope-token
    syntax. When the key is absent, the document names the union of the
    `required_scopes` of the DSL modules instead and omits the field
    when that union is empty. A client that gets no `scope` parameter
    in a challenge asks for all the scopes of the list: to keep the
    least privilege, set `challenge_scopes` or set `scopes_supported`.
  * `challenge_scopes` — the scopes named in the `WWW-Authenticate`
    header of a `401` or a `403` when the verifier gives none of its own.
  * `filter_by_scope` — a boolean, default `true`. When `false`, the list
    methods (`tools/list`, `resources/list`, `resources/templates/list`
    and `prompts/list`) return every entity: only the calls are refused
    by scope. See `OzMcp.Auth.Scopes`.
  * `audience_check` — a boolean, default `true`. When `false`, the gate
    skips the check that the audience of the token (`aud`, RFC 8707)
    names this server. See OzMcp.Auth.Audience.
  * `resource_name`, `resource_documentation` — optional fields of the
    metadata document (the second one is an http(s) URL).

  The canonical URL of the endpoint is not part of the block: it is the
  runtime option `:resource_url` of `OzMcp`, so a release can
  read it from the environment. The runtime refuses to boot when the
  block is declared without it, or when it is set without the block.
  """

  alias OzMcp.Config.DSL.{Checks, Core, Rules, Shared}
  alias OzMcp.Structs.{Implementation, ServerCapabilities}

  require OzMcp.Config.DSL.Generate

  @import_macros [
    protocol_version: 1,
    instructions: 1,
    server_info: 1,
    capabilities: 1,
    tools: 1,
    resources: 1,
    templates: 1,
    prompts: 1,
    authorization: 1,
    meta: 2,
    extra: 2
  ]

  @task_requests [[:capabilities, :tasks]]
  @registries [[:tools], [:resources], [:templates], [:prompts]]
  @auth [[:authorization]]
  @info [[:server_info]]

  @list_results [
    [:tools, :list_result],
    [:resources, :list_result],
    [:templates, :list_result],
    [:prompts, :list_result]
  ]

  @properties Map.merge(Shared.icon_properties([:server_info]), %{
                protocol_version: %{
                  paths: [[]],
                  field: :protocol_version,
                  type: [:non_empty_string, {:rule, &Rules.protocol_version/1}]
                },
                instructions: %{paths: [[]], field: :instructions, type: :non_empty_string},
                name: %{paths: @info, field: :name, type: :non_empty_string},
                version: %{paths: @info, field: :version, type: :non_empty_string},
                title: %{paths: @info, field: :title, type: :non_empty_string},
                description: %{paths: @info, field: :description, type: :non_empty_string},
                website_url: %{paths: @info, field: :websiteUrl, type: :non_empty_string},
                paginate: %{
                  paths: @registries,
                  field: :paginate,
                  type: {:positive_integer, "a positive integer"}
                },
                subscribe: %{
                  paths: [[:capabilities, :resources]],
                  field: :subscribe,
                  type: :boolean
                },
                tool: %{paths: [[:tools]], field: :modules, type: :module, append: :tools},
                prompt: %{paths: [[:prompts]], field: :modules, type: :module, append: :prompts},
                resource: %{
                  paths: [[:resources]],
                  field: :modules,
                  type: :module,
                  append: :resources
                },
                template: %{
                  paths: [[:templates]],
                  field: :modules,
                  type: :module,
                  append: :templates
                },
                experimental: %{
                  paths: [[:capabilities]],
                  field: :experimental,
                  type: [:map, :non_empty_map, {:raises, &Checks.experimental_keys!/1}]
                },
                logging: %{paths: [[:capabilities]], field: :logging, type: [:map, :empty_map]},
                completions: %{
                  paths: [[:capabilities]],
                  field: :completions,
                  type: [:map, :empty_map]
                },
                list: %{paths: @task_requests, field: :list, type: :map},
                cancel: %{paths: @task_requests, field: :cancel, type: :map},
                requests: %{paths: @task_requests, field: :requests, type: :map},
                verifier: %{paths: @auth, field: :verifier, type: :module},
                authorization_servers: %{
                  paths: @auth,
                  field: :authorization_servers,
                  type: [{:list, "a list of URLs"}, :non_empty_list]
                },
                scopes_supported: %{
                  paths: @auth,
                  field: :scopes_supported,
                  type: {:list, "a list of strings"}
                },
                challenge_scopes: %{
                  paths: @auth,
                  field: :challenge_scopes,
                  type: {:list, "a list of strings"}
                },
                filter_by_scope: %{paths: @auth, field: :filter_by_scope, type: :boolean},
                audience_check: %{paths: @auth, field: :audience_check, type: :boolean},
                resource_name: %{paths: @auth, field: :resource_name, type: :non_empty_string},
                resource_documentation: %{
                  paths: @auth,
                  field: :resource_documentation,
                  type: :non_empty_string
                }
              })

  @blocks Map.merge(Shared.icon_block([:server_info]), %{
            server_info: %{
              paths: [[]],
              field: :server_info,
              initial: Implementation,
              finish: {__MODULE__, :__check_server_info__, []}
            },
            capabilities: %{
              paths: [[]],
              field: :capabilities,
              initial: ServerCapabilities
            },
            tools: Shared.list_block(:tools, "tool"),
            resources: Shared.list_block(:resources, "resource"),
            prompts: Shared.list_block(:prompts, "prompt"),
            templates: %{
              paths: [[]],
              field: :templates,
              initial: %{paginate: nil, list_result: nil, modules: []},
              finish: {Checks, :modules!, ["template"]}
            },
            list_result: %{
              paths: @registries,
              field: :list_result,
              initial: %{_meta: nil, extras: nil},
              finish: {Checks, :not_empty!, [[:_meta, :extras], "list_result"]}
            },
            tasks: %{
              paths: [[:capabilities]],
              field: :tasks,
              initial: %{list: nil, cancel: nil, requests: nil},
              finish: {__MODULE__, :__compact_tasks__, []}
            },
            authorization: %{
              paths: [[]],
              field: :authorization,
              initial: %{
                verifier: nil,
                authorization_servers: [],
                scopes_supported: nil,
                challenge_scopes: [],
                filter_by_scope: nil,
                audience_check: nil,
                resource_name: nil,
                resource_documentation: nil
              },
              finish: {__MODULE__, :__finish_authorization__, []}
            }
          })

  @pairs %{
    meta: %{paths: [[] | @list_results], field: :_meta, key: &Checks.meta_pair_key!/2},
    extra: %{paths: [[] | @list_results], field: :extras, key: &Checks.extra_pair_key!/2}
  }

  OzMcp.Config.DSL.Generate.macros()

  # ---------- Hooks

  @doc false
  @spec __check_server_info__(Implementation.t()) :: Implementation.t()
  def __check_server_info__(data) do
    if data.name == "", do: raise("'name' is required")
    if data.version == "", do: raise("'version' is required")
    data
  end

  # Drop nil members so they are never serialized as JSON null.
  #
  @doc false
  @spec __compact_tasks__(map()) :: map()
  def __compact_tasks__(data), do: Map.reject(data, fn {_key, value} -> is_nil(value) end)

  @doc false
  @spec __finish_authorization__(map()) :: map()
  def __finish_authorization__(data) do
    __check_authorization__!(data)

    # nil means "not declared": the default is true
    #
    data
    |> Map.put(:filter_by_scope, data.filter_by_scope != false)
    |> Map.put(:audience_check, data.audience_check != false)
  end

  @doc false
  def __check_authorization__!(data) do
    check_authorization_verifier!(Map.fetch!(data, :verifier))
    check_authorization_servers!(Map.fetch!(data, :authorization_servers))
    check_authorization_scopes!(:scopes_supported, Map.fetch!(data, :scopes_supported))
    check_authorization_scopes!(:challenge_scopes, Map.fetch!(data, :challenge_scopes))
    check_authorization_documentation!(Map.fetch!(data, :resource_documentation))
  end

  defp check_authorization_verifier!(nil) do
    raise ArgumentError, "'verifier' is required in the authorization block"
  end

  defp check_authorization_verifier!(verifier) when is_atom(verifier), do: :ok

  defp check_authorization_verifier!(verifier) do
    raise ArgumentError, "'verifier' must be a module (atom), got: #{inspect(verifier)}"
  end

  defp check_authorization_servers!(servers) do
    if not is_list(servers) or servers == [] do
      raise ArgumentError,
            "'authorization_servers' must be a non-empty list of URLs, got: #{inspect(servers)}"
    end

    Enum.each(servers, fn server ->
      unless valid_authorization_server_url?(server) do
        raise ArgumentError,
              "'authorization_servers' entries must be https URLs " <>
                "(http is allowed only for a loopback host: localhost, 127.0.0.1, ::1), " <>
                "got: #{inspect(server)}"
      end
    end)
  end

  defp check_authorization_scopes!(_key, nil), do: :ok

  defp check_authorization_scopes!(key, scopes) do
    if not is_list(scopes) or not Enum.all?(scopes, &OzMcp.Auth.scope_token?/1) do
      raise ArgumentError,
            "'#{key}' entries must match the RFC 6749 scope-token syntax, got: #{inspect(scopes)}"
    end
  end

  defp check_authorization_documentation!(nil), do: :ok

  defp check_authorization_documentation!(url) do
    unless valid_documentation_url?(url) do
      raise ArgumentError, "'resource_documentation' must be an http(s) URL, got: #{inspect(url)}"
    end
  end

  defp valid_authorization_server_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        scheme = String.downcase(scheme)

        scheme == "https" or (scheme == "http" and OzMcp.Auth.loopback_host?(host))

      _ ->
        false
    end
  end

  defp valid_authorization_server_url?(_url), do: false

  defp valid_documentation_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        String.downcase(scheme) in ["http", "https"]

      _ ->
        false
    end
  end

  defp valid_documentation_url?(_url), do: false

  # ---------- Using

  defmacro __using__(_opts) do
    quote do
      import OzMcp.Config.Server.DSL, only: unquote(@import_macros)

      unquote(Core).init(__MODULE__, %{
        _meta: nil,
        protocol_version: nil,
        instructions: nil,
        server_info: nil,
        capabilities: nil,
        tools: nil,
        resources: nil,
        templates: nil,
        prompts: nil,
        extras: nil,
        authorization: nil
      })

      @before_compile unquote(__MODULE__)
    end
  end

  defmacro __before_compile__(env) do
    Module.delete_attribute(env.module, :__path__)
    Module.delete_attribute(env.module, :__defined__)
    Module.delete_attribute(env.module, :__cache__)

    config = Module.get_attribute(env.module, :__config__)

    config = %{config | protocol_version: config.protocol_version || OzMcp.Protocol.latest()}

    if is_nil(config.server_info) do
      raise RuntimeError, "'server_info' is required"
    end

    if is_nil(config.tools) and is_nil(config.resources) and is_nil(config.templates) and
         is_nil(config.prompts) do
      raise RuntimeError, "at least one tool, resource, template or prompt must be defined"
    end

    capabilities = config.capabilities || %ServerCapabilities{}

    no_resource_capability = is_nil(capabilities.resources)
    no_resources_or_templates = is_nil(config.resources) and is_nil(config.templates)

    capabilities =
      if is_nil(config.tools), do: capabilities, else: %{capabilities | tools: %{}}

    capabilities =
      cond do
        not no_resource_capability and no_resources_or_templates ->
          raise RuntimeError,
                "if you declare resource capability then you must at least define one resource or one template"

        not no_resources_or_templates and no_resource_capability ->
          %{capabilities | resources: %{}}

        true ->
          capabilities
      end

    capabilities =
      if is_nil(config.prompts), do: capabilities, else: %{capabilities | prompts: %{}}

    config = Map.put(config, :capabilities, capabilities)

    quote do
      @__config__ unquote(Macro.escape(config))
      def config, do: @__config__
    end
  end
end
