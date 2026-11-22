#
# The tool factory is a helper module used to generate tool configuration modules
# using the DSL.
#
# ## Generate and compile a tool configuration module
#
#     import Support.Factories.Tool
#
#     module =
#       module "GetDate" do
#         tool "get_date" do
#           title "Get the current date"
#           description "Get the current date formatted as %d/%m/%Y"
#         end
#       end
#       |> compile()
#
#     module.list()
#
# ## Generate and get the source code (usefull for debugging)
#
#     import Support.Factories.Tool
#
#     source =
#       module "GetDate" do
#         tool "get_date" do
#           title "Get the current date"
#           description "Get the current date formatted as %d/%m/%Y"
#         end
#       end
#       |> source()
#
#     IO.puts(source)
#
# This will generate the following tool configuration module:
#
#     defmodule Support.Generated.Tool.GetDate_3234 do
#       use OzMcp.Config.Tool, warn?: false
#
#       tool("get_date") do
#         title("Get the current date")
#         description("Get the current date formatted as %d/%m/%Y")
#       end
#
#       def(call(_ctx, _params)) do
#         nil
#       end
#     end
#
# ## Enabling/Disabling warning
#
# By default the tool module is generated with warning set to `false`.
#
# When testing warnings you can set it to `true`:
#
#     import Support.Factories.Tool
#
#     module "Using", _warn_: true do
#       tool "get_date"
#     end
#     |> source()
#     |> IO.puts()
#
# This will generate the following tool configuration module:
#
#     defmodule Support.Generated.Tool.Using_3234 do
#       use OzMcp.Config.Tool, warn?: true
#
#       tool("get_date") do
#       end
#
#       def(call(_ctx, _params)) do
#         nil
#       end
#     end
#
# To test the default value of warn option:
#
#     import Support.Factories.Tool
#
#     module "Using", _warn_: _none_ do
#       tool "get_date"
#     end
#     |> source()
#     |> IO.puts()
#
# This will generate the following tool configuration module:
#
#     defmodule Support.Generated.Tool.Using_3234 do
#       use OzMcp.Config.Tool
#
#       tool("get_date") do
#       end
#
#       def(call(_ctx, _params)) do
#         nil
#       end
#     end
#
# ## Enforcing the tool name rule
#
# Pass `_strict_names_: true` to generate a module with the option
# `strict_names?: true`. A tool name outside the name rule then raises
# at compile time:
#
#     import Support.Factories.Tool
#
#     module "Strict", _strict_names_: true do
#       tool "get date"
#     end
#     |> assert_compile_raise(ArgumentError, "tool name must be 1 to 128 characters")
#
# ## Example
#
#     import Support.Factories.Tool
#
#     module "Full" do
#       tool "get_date" do
#         title "Get the current date"
#         description "Get the current date formatted as %d/%m/%Y"
#
#         input_schema %{type: "object", properties: %{}}
#         output_schema %{type: "object", properties: %{}}
#
#         execution do
#           task_support "optional"
#         end
#
#         icon do
#           mime_type "image/png"
#           sizes ["32x32", "64x64"]
#         end
#
#         annotations do
#           title "Safe date lookup"
#           read_only_hint true
#           destructive_hint false
#           idempotent_hint true
#           open_world_hint false
#         end
#
#         meta "key1", "value1"
#         meta "key2", "value2"
#       end
#     end
#     |> source()
#     |> IO.puts()
#
# This will generate the following tool configuration module:
#
#     defmodule Support.Generated.Tool.Full_482 do
#       use OzMcp.Config.Tool, warn?: false
#
#       tool("get_date") do
#         input_schema(%{properties: %{}, type: "object"})
#         output_schema(%{properties: %{}, type: "object"})
#         title("Get the current date")
#         description("Get the current date formatted as %d/%m/%Y")
#
#         execution do
#           task_support("optional")
#         end
#
#         icon do
#           src("https://z.net/icon.png")
#           mime_type("image/png")
#           sizes(["32x32", "64x64"])
#         end
#
#         annotations do
#           title("Safe date lookup")
#           read_only_hint(true)
#           destructive_hint(false)
#           idempotent_hint(true)
#           open_world_hint(false)
#         end
#
#         meta("key1", "value1")
#         meta("key2", "value2")
#       end
#
#       def(call(_ctx, _params)) do
#         nil
#       end
#     end
#
# ## Using keyword arguments or code block
#
#     import Support.Factories.Tool
#
#     module "Kw" do
#       tool "get_date", title: "T", description: "D" do
#         icon()
#
#         icon(mime_type: "image/png", sizes: ["32x32", "64x64"])
#
#         icon do
#           mime_type "image/png"
#           sizes ["32x32", "64x64"]
#         end
#       end
#     end
#     |> source()
#     |> IO.puts()
#
# This will generate the following tool configuration module:
#
#     defmodule Support.Generated.Tool.Kw_1602 do
#       use OzMcp.Config.Tool, warn?: false
#
#       tool("get_date") do
#         title("T")
#         description("D")
#
#         icon do
#           src("https://z.net/icon.png")
#         end
#
#         icon do
#           src("https://z.net/icon.png")
#           mime_type("image/png")
#           sizes(["32x32", "64x64"])
#         end
#
#         icon do
#           src("https://z.net/icon.png")
#           mime_type("image/png")
#           sizes(["32x32", "64x64"])
#         end
#       end
#
#       def(call(_ctx, _params)) do
#         nil
#       end
#     end
#
# ## Specific tests
#
#     import Support.Factories.Tool
#
#     module "Specific" do
#       # Set a specific input_schema.
#       tool "get_date", input_schema: %{type: "object"} do
#       end
#
#       # Used to test duplicates input_schema declaration.
#       tool "get_date", input_schema: %{type: "object"} do
#         input_schema %{type: "object", properties: %{}}
#       end
#     end
#     |> source()
#     |> IO.puts()
#
# This will generate the following tool configuration module:
#
#     defmodule Support.Generated.Tool.Specific_1346 do
#       use OzMcp.Config.Tool, warn?: false
#
#       tool("get_date") do
#         input_schema(%{type: "object"})
#       end
#
#       tool("get_date") do
#         input_schema(%{type: "object"})
#         input_schema(%{properties: %{}, type: "object"})
#       end
#
#       def(call(_ctx, _params)) do
#         nil
#       end
#     end
#
# ## Get a single tool
#
# `compile_one_tool/1` compiles the module and returns its only declared tool
# (asserting exactly one was declared).
#
#     import Support.Factories.Tool
#
#     tool =
#       module "Single" do
#         tool "get_date" do
#           annotations(read_only_hint: true)
#         end
#       end
#       |> compile_one_tool()
#
#     assert tool.annotations.readOnlyHint == true
#
# ## Assert raise at compilation time
#
#     import Support.Factories.Tool
#
#     module "Bad" do
#       tool "t" do
#         title "First"
#         title "Second"
#       end
#     end
#     |> assert_compile_raise(RuntimeError, "cannot declare 'title' multiple times")
#
# `assert_compile_raise/4` additionally asserts that the captured stderr contains
# the given string. Use it for `CompileError` — in the tool DSL this happens at
# the module root, where only `tool/2` is imported so any other macro is an
# undefined function:
#
#     import Support.Factories.Tool
#
#     module "Bad" do
#       title "root-level"
#     end
#     |> assert_compile_raise(
#       CompileError,
#       ~r"nofile: cannot compile module Support.Generated.Tool.Bad",
#       "undefined function title/1"
#     )
#
# ## Assert warning at compilation time
#
# Use `assert_compile_warning/2` to assert warning presence:
#
#     import Support.Factories.Tool
#
#     module "Warn", _warn_: true do
#       tool "get_date", description: "A tool"
#     end
#     |> assert_compile_warning("The tool get_date does not have a title configuration")
#
# Use `refute_compile_warning/2` to refute warnings presence:
#
#     module "NoWarn" do
#       tool "get_date"
#     end
#     |> refute_compile_warning([
#       "does not have a title configuration",
#       "does not have a description configuration"
#     ])
#
# ## Disabling the DSL
#
# The DSL is activated by default (`use OzMcp.Config.Tool`). Pass `_dsl_: false` to deactivate
# it. Only `list/0` is required.
#
#     import Support.Factories.Tool
#
#     code =
#       quote do
#         def list(), do: []
#       end
#
#     module("Tools", _dsl_: false, _code_: code)
#     |> compile()
#
# ## Code injection
#
# `_code_:` injects arbitrary expressions into the generated module. It is mainly
# used to test `__before_compile__/1` collisions, e.g. defining `list/0` while the
# DSL is active:
#
#     import Support.Factories.Tool
#
#     code =
#       quote do
#         def list(), do: []
#       end
#
#     module("Bad", _code_: code) do
#       tool "get_date"
#     end
#     |> assert_compile_raise(
#       RuntimeError,
#       "when using the tool DSL you can't declare list/0 function"
#     )
#
# ## The `call/2` callback
#
# `OzMcp.Config.Tool` requires a `call/2` callback that the DSL never
# auto-generates. To keep every generated module free of compiler errors,
# Support.Factories.Tool injects a default `def call(_ctx, _params), do: {:error, :no_tool}` unless:
#
#   * the injected code already defines `call` (detected through the
#     `_code_` option), or
#   * the auto-injection is disabled with `_call_: :_none_`.
#
# Use `_call_: :_none_` when you want to observe the
# `you must satisfy the call/2 behaviour` compile error, or when you provide
# a custom `call/2` through `_code_`.
#
defmodule Support.Factories.Tool do
  use Support.Factories.Kit

  def compile_one_tool(ast) do
    [tool] = compile(ast).list()
    tool
  end

  defmacro module(name, opts \\ []) do
    {block, kw} = Keyword.pop(opts, :do)
    Support.Factories.Kit.build(__MODULE__, :__module__, [name], kw, block)
  end

  defmacro module(name, opts, do: block) do
    Support.Factories.Kit.build(__MODULE__, :__module__, [name], opts, block)
  end

  @doc false
  def __module__(name, opts, exprs) do
    code = code(opts)

    use_opts =
      Support.Factories.Kit.use_opts(opts,
        _dsl_: :dsl?,
        _warn_: :warn?,
        _strict_names_: :strict_names?,
        _strict_tasks_: :strict_tasks?
      )

    call_exprs =
      case Keyword.get(opts, :_call_, :auto) do
        :_none_ -> []
        :auto -> if has_def?(code, :call), do: [], else: [default_call()]
      end

    quote do
      defmodule unquote(Support.Factories.Kit.unique("Support.Generated.Tool", name)) do
        (unquote_splicing(
           [use_line(quote(do: OzMcp.Config.Tool), use_opts)] ++ exprs ++ code ++ call_exprs
         ))
      end
    end
  end

  block(:tool,
    named: true,
    lines: [title: :_none_, description: :_none_, input_schema: :_none_, output_schema: :_none_]
  )

  block(:annotations,
    lines: [
      title: :_none_,
      read_only_hint: :_none_,
      destructive_hint: :_none_,
      idempotent_hint: :_none_,
      open_world_hint: :_none_
    ]
  )

  block(:icon,
    lines: [src: "https://z.net/icon.png", mime_type: :_none_, sizes: :_none_, theme: :_none_]
  )

  block(:execution, lines: [task_support: :_none_])

  props(
    plain: [
      :title,
      :description,
      :src,
      :mime_type,
      :theme,
      :read_only_hint,
      :destructive_hint,
      :idempotent_hint,
      :open_world_hint,
      :task_support,
      :poll_interval,
      :immediate_response
    ],
    escaped: [:required_scopes, :input_schema, :output_schema, :sizes],
    keyed: [:meta]
  )

  defp default_call do
    quote do
      def call(_ctx, _params), do: {:error, :no_tool}
    end
  end
end
