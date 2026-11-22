defmodule OzMcp.Config.Tool do
  @moduledoc """
  Behaviour for MCP tool modules.

  ## Two ways to declare the tools

  | Way | `use` | What you write | What the framework generates |
  |---|---|---|---|
  | DSL | `use OzMcp.Config.Tool` | one `tool "name" do ... end` block for each tool and `call/2` | `list/0`. The DSL checks the schemas at compile time. |
  | Data | `use OzMcp.Config.Tool, dsl?: false` | `list/0` that returns `%OzMcp.Structs.Tool{}` structs or maps with the wire keys (`name`, `inputSchema`, ...) and `call/2` | nothing |

  Rules for the way with `dsl?: false`:

    * A map carries `required_scopes` like a struct: the boot of the
      instance reads the key, checks it and it never reaches the
      client.
    * The boot check of duplicate names reads `list/0` of a module one
      time at boot.

  The guide [Tools](guides/entities/tools.md) shows an example of each
  way.

  ## Static schemas and schema validation

  The server reads a module one time, at the boot of the instance and
  answers a lookup from a map in the catalog. A change of a module
  needs a stop and a start of the instance.

  A `dsl?: true` tool (the default) that declares an invalid
  `inputSchema` or `outputSchema` fails at compile time; the root of
  each schema must have the type `"object"`. A tool with `dsl?: false`
  is checked at the boot of the instance. The guide
  [Tools](guides/entities/tools.md) gives the details of each check.

  ## Output schema

  When a tool declares an `outputSchema`, the server checks each result
  of the tool before it sends the result:

    * A result with `isError: true` is not checked.
    * Each other result must have a `structuredContent` that is an
      object and that agrees with the `outputSchema`.
    * The check uses the JSON form of `structuredContent`: atom keys and
      atom values are strings, as on the wire.

  A result that does not obey these rules gives the JSON-RPC error
  `-32603` `"tool output does not match outputSchema"`. The `data` of
  the error holds the messages. A task-augmented call gets the same
  check: the task becomes `failed` and `tasks/result` gives the same
  error.

  ## Required scopes

  Declare `required_scopes [...]` in a `tool` block: a `tools/call`
  without all the scopes gets `403` and `tools/list` hides the tool
  from a principal that lacks them. A tool declared with `dsl?: false`
  carries the scopes in the key `required_scopes` of a map, or in the
  field of the struct. The guide about the authorization gives the
  rules of the scopes and of the filter of the lists.

  ## Unique key

  The `name` of a tool is unique in the module: two tools with the same
  `name` raise at compile time. The `name` is unique in the server too:
  the runtime refuses to boot when two tool modules of one server
  declare the same `name`. The boot check reads `list/0` of each
  module.
  """

  alias OzMcp.Config.Use
  alias OzMcp.Context
  alias OzMcp.Structs.{CallToolResult, Tool}
  alias OzMcp.Utils.{Error, JsonSchemaValidator}

  # ------------------------------------------------------------------
  # Behaviour definition
  # ------------------------------------------------------------------

  @type name :: String.t()

  @type rpc_params :: map()

  @type call_result ::
          {:ok, %CallToolResult{}}
          | {:ok, map()}
          | {:error, %Error{}}

  @doc """
  Returns the tools of the module: `%OzMcp.Structs.Tool{}` structs, or
  maps with the wire keys.

  The DSL generates it. The boot of the instance calls it one time.
  """
  @callback list() :: list(%Tool{}) | list(map())

  @doc """
  Runs the tool `params["name"]` with the arguments
  `params["arguments"]`.

  `params` is the full `params` object of `tools/call`. The input
  schema of the tool checked the arguments and gave the default
  values, before the call.

  Return:

    * `{:ok, %CallToolResult{}}` or `{:ok, map}`: the result of the
      tool. Set `isError: true` for an error that the model can
      correct.
    * `{:error, %OzMcp.Utils.Error{}}`: a protocol error, for example
      an unknown tool (`-32602`).

  Each other return value gives the client a `-32603` error. The
  callback runs in a supervised process of its own, after the request
  process.

  ## Example

      @impl true
      def call(_ctx, %{"name" => "echo", "arguments" => %{"text" => text}}) do
        {:ok, %{content: [%{type: "text", text: text}]}}
      end
  """
  @callback call(Context.ctx(), rpc_params()) :: call_result()

  # ------------------------------------------------------------------
  # Using
  # ------------------------------------------------------------------

  @tool_options [strict_names?: false, strict_tasks?: false]

  defmacro __using__(opts), do: Use.using(__MODULE__, __CALLER__, opts, @tool_options)

  defmacro __before_compile__(env),
    do: Use.before_compile(env, {:call, 2}, &tool_functions(env, &1))

  defp tool_functions(env, options) do
    #
    # Tools declared with the DSL leave their config in @__config__. Each
    # inputSchema and outputSchema is validated here, so an invalid schema
    # fails the compilation of the tool module. The catalog builds the
    # root of a static tool at boot (see OzMcp.Catalog). Tools declared
    # with dsl?: false have no @__config__. Their schemas are checked at
    # boot by the catalog.
    #
    env.module
    |> Module.get_attribute(:__config__)
    |> compile_schemas!(env.module)

    # A DSL module gets its names checked by the compiler. The boot checks
    # the names of the other modules, with the rule that this function gives.
    #
    name_rule_ast = name_rule_ast(options)

    # The boot reads this rule for a static module of both kinds: a
    # refusal of the boot, a warning in the log, or nothing.
    #
    task_rule_ast =
      quote do
        @doc false
        def __task_rule__, do: unquote(rule(options.strict_tasks?, options.warn?))
      end

    quote do
      unquote(name_rule_ast)
      unquote(task_rule_ast)
    end
  end

  defp name_rule_ast(%{dsl?: true}), do: nil

  defp name_rule_ast(options) do
    quote do
      @doc false
      def __name_rule__, do: unquote(rule(options.strict_names?, options.warn?))
    end
  end

  defp rule(true, _warn?), do: :strict
  defp rule(false, true), do: :warn
  defp rule(false, false), do: :off

  # ------------------------------------------------------------------
  # Schema compilation
  # ------------------------------------------------------------------

  defp compile_schemas!(nil, _module), do: :ok

  defp compile_schemas!(config, module) when is_list(config) do
    Enum.each(config, fn %Tool{} = tool ->
      Enum.each([:input, :output], fn kind ->
        compile_schema!({module, tool.name, kind}, schema_of(tool, kind))
      end)
    end)
  end

  defp schema_of(tool, :input), do: tool.inputSchema
  defp schema_of(tool, :output), do: tool.outputSchema

  defp compile_schema!(_key, nil), do: :ok

  defp compile_schema!(_key, schema) when schema == %{}, do: :ok

  defp compile_schema!(key, schema) when is_map(schema) do
    JsonSchemaValidator.check_validate!(key, schema)
  end
end
