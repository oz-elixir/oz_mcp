defmodule OzMcp.Config.Server do
  @moduledoc """
  Behaviour of a server module. A server module declares one MCP
  server: its information, its capabilities and the modules of its
  tools, resources, templates and prompts.

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

  `use OzMcp.Config.Server` includes `OzMcp.Config.Server.DSL`. The
  blocks of the DSL check the declaration at compile time and the
  macros generate the functions of this behaviour:

    * `config/0`: the configuration of the server.
    * `initialize_result/0`: the `t:OzMcp.Structs.InitializeResult.t/0`
      of the server.
    * `authorization/0`: the map of the `authorization` block, or
      `nil`.
    * For each kind (`tools`, `resources`, `templates`, `prompts`):
      `paginate_<kind>/0`. For example `paginate_tools/0`.
    * `list_<kind>_result_meta/0` and `list_<kind>_result_extras/0`
      for the `list_result` block of each registry block.

  The application does not implement the callbacks of the lists. The
  DSL generates them and it checks that the key of each entity (the
  name of a tool or of a prompt, the uri of a resource, the
  `uri_template` of a template) is unique in the server. The optional
  callback `roots_list_changed/1` has a default: override it to react
  to a change of the roots of the client.

  The guide *Declare a server* describes each block of the DSL.
  """

  alias OzMcp.Structs.InitializeResult

  # ------------------------------------------------------------------
  # Behaviour definition
  # ------------------------------------------------------------------

  @type name :: String.t()

  @type uri :: String.t()

  @type uri_template :: String.t()

  @doc """
  Returns the `t:OzMcp.Structs.InitializeResult.t/0` of the server: the
  protocol version, the server information, the capabilities, the
  instructions and the root `_meta`. Generated. The framework sends it
  as the answer to `initialize`. The application does not implement it.
  """
  @callback initialize_result() :: %InitializeResult{} | map()

  @doc """
  Called when a client that declared the `roots` capability sends
  `notifications/roots/list_changed`: its list of roots changed.

  Optional: the default does nothing. Override it in the server module to
  react (for example, call `OzMcp.Client.list_roots/2` to read the new
  roots). `ctx` is the short context of the callbacks (without a request id:
  the client sent a notification). The function runs in its own process, after
  the notification was accepted; its result is ignored and a failure is only
  logged.

  The calls are bounded (see OzMcp.RootsChanged): at most one run per
  session at a time, a burst of notifications that arrives while it runs is
  one more run afterwards and a run is stopped at the `request_timeout_ms` of
  the server (5 minutes when there is none). Do not rely on one call per
  notification: read the roots, do not count the notifications.

  There is no request, so there is no response stream for the calls of
  `OzMcp.Client`: they need an open `GET` stream of the session and fail with
  `{:error, :no_stream}` otherwise. Pass `wait_for_stream: true` to queue the
  request for the next stream.
  """
  @callback roots_list_changed(ctx :: OzMcp.Context.ctx()) :: any()

  @doc """
  The static authorization configuration of the server, or `nil` when the
  server module declares no `authorization` block. The map holds the keys
  declared in the block: `verifier`, `authorization_servers`,
  `scopes_supported`, `challenge_scopes`, `filter_by_scope`,
  `audience_check`, `resource_name` and `resource_documentation`.
  `filter_by_scope` is a boolean (default `true`): when `false`, the list
  methods return every entity and only the calls are refused by scope.
  `audience_check` is a boolean (default `true`): when `false`, the gate
  skips the check that the audience of the token names this server.
  """
  @callback authorization() :: map() | nil

  @optional_callbacks roots_list_changed: 1, authorization: 0

  @doc """
  Returns the page size of the `tools` block of the server, or `nil`
  when the block has no `paginate`. Generated. The application does not
  implement it.
  """
  @callback paginate_tools() :: non_neg_integer() | nil

  @doc """
  Returns the page size of the `resources` block of the server, or
  `nil` when the block has no `paginate`. Generated. The application
  does not implement it.
  """
  @callback paginate_resources() :: non_neg_integer() | nil

  @doc """
  Returns the page size of the `templates` block of the server, or
  `nil` when the block has no `paginate`. Generated. The application
  does not implement it.
  """
  @callback paginate_templates() :: non_neg_integer() | nil

  @doc """
  Returns the page size of the `prompts` block of the server, or `nil`
  when the block has no `paginate`. Generated. The application does not
  implement it.
  """
  @callback paginate_prompts() :: non_neg_integer() | nil

  # ------------------------------------------------------------------
  # Using
  # ------------------------------------------------------------------

  defmacro __using__(_opts) do
    quote do
      use OzMcp.Config.Server.DSL
      @behaviour OzMcp.Config.Server
      @before_compile OzMcp.Config.Server

      @doc false
      def roots_list_changed(_ctx), do: :ok
      defoverridable roots_list_changed: 1
    end
  end

  defmacro __before_compile__(env) do
    config = Module.get_attribute(env.module, :__config__)

    initialize_result =
      %InitializeResult{}
      |> InitializeResult._meta(config._meta)
      |> InitializeResult.protocol_version(config.protocol_version)
      |> InitializeResult.instructions(config.instructions)
      |> InitializeResult.server_info(config.server_info)
      |> InitializeResult.capabilities(config.capabilities)
      |> InitializeResult.extras(config.extras)
      |> InitializeResult.build()

    quote do
      def initialize_result, do: unquote(Macro.escape(initialize_result))

      def authorization, do: config().authorization

      unquoted_config = unquote(Macro.escape(config))

      # --------------------------------------------
      # About tools
      # --------------------------------------------

      if unquoted_config.tools do
        def paginate_tools, do: config().tools.paginate

        if unquoted_config.tools.list_result do
          def list_tools_result_meta, do: config().tools.list_result._meta
          def list_tools_result_extras, do: config().tools.list_result.extras
        else
          def list_tools_result_meta, do: nil
          def list_tools_result_extras, do: nil
        end
      else
        def paginate_tools, do: nil
        def list_tools_result_meta, do: nil
        def list_tools_result_extras, do: nil
      end

      # --------------------------------------------
      # About resources
      # --------------------------------------------

      if unquoted_config.resources do
        def paginate_resources, do: config().resources.paginate

        if unquoted_config.resources.list_result do
          def list_resources_result_meta, do: config().resources.list_result._meta
          def list_resources_result_extras, do: config().resources.list_result.extras
        else
          def list_resources_result_meta, do: nil
          def list_resources_result_extras, do: nil
        end
      else
        def paginate_resources, do: nil
        def list_resources_result_meta, do: nil
        def list_resources_result_extras, do: nil
      end

      # --------------------------------------------
      # About templates
      # --------------------------------------------

      if unquoted_config.templates do
        def paginate_templates, do: config().templates.paginate

        if unquoted_config.templates.list_result do
          def list_resource_templates_result_meta,
            do: config().templates.list_result._meta

          def list_resource_templates_result_extras,
            do: config().templates.list_result.extras
        else
          def list_resource_templates_result_meta, do: nil
          def list_resource_templates_result_extras, do: nil
        end
      else
        def paginate_templates, do: nil
        def list_resource_templates_result_meta, do: nil
        def list_resource_templates_result_extras, do: nil
      end

      # --------------------------------------------
      # About prompts
      # --------------------------------------------

      if unquoted_config.prompts do
        def paginate_prompts, do: config().prompts.paginate

        if unquoted_config.prompts.list_result do
          def list_prompts_result_meta, do: config().prompts.list_result._meta
          def list_prompts_result_extras, do: config().prompts.list_result.extras
        else
          def list_prompts_result_meta, do: nil
          def list_prompts_result_extras, do: nil
        end
      else
        def paginate_prompts, do: nil
        def list_prompts_result_meta, do: nil
        def list_prompts_result_extras, do: nil
      end
    end
  end
end
