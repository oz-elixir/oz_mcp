#
# The prompt factory is a helper module used to generate prompt configuration modules
# using the DSL.
#
# ## Generate and compile a prompt configuration module
#
#     import Support.Factories.Prompt
#
#     module =
#       module "CodeReview" do
#         prompt "code_review" do
#           title "Code review"
#           description "Reviews code"
#
#           argument "language", required: true, description: "Programming language"
#         end
#       end
#       |> compile()
#
#     module.list()
#
# ## Generate and get the source code (usefull for debugging)
#
#     import Support.Factories.Prompt
#
#     source =
#       module "CodeReview" do
#         prompt "code_review" do
#           title "Code review"
#           description "Reviews code"
#         end
#       end
#       |> source()
#
#     IO.puts(source)
#
# This will generate the following prompt configuration module:
#
#     defmodule Support.Generated.Prompt.CodeReview_3234 do
#       use OzMcp.Config.Prompt, warn?: false
#
#       prompt("code_review") do
#         title("Code review")
#         description("Reviews code")
#       end
#
#       def(get(_ctx, _params)) do
#         {:error, :no_prompt}
#       end
#     end
#
# ## Enabling/Disabling warning
#
# By default the prompt module is generated with warning set to `false`.
#
# When testing warnings you can set it to `true`:
#
#     import Support.Factories.Prompt
#
#     module "Using", _warn_: true do
#       prompt "code_review"
#     end
#     |> source()
#     |> IO.puts()
#
# This will generate the following prompt configuration module:
#
#     defmodule Support.Generated.Prompt.Using_3234 do
#       use OzMcp.Config.Prompt, warn?: true
#
#       prompt("code_review") do
#       end
#
#       def(get(_ctx, _params)) do
#         {:error, :no_prompt}
#       end
#     end
#
# To test the default value of warn option:
#
#     import Support.Factories.Prompt
#
#     module "Using", _warn_: _none_ do
#       prompt "code_review"
#     end
#     |> source()
#     |> IO.puts()
#
# This will generate the following prompt configuration module:
#
#     defmodule Support.Generated.Prompt.Using_3234 do
#       use OzMcp.Config.Prompt
#
#       prompt("code_review") do
#       end
#
#       def(get(_ctx, _params)) do
#         {:error, :no_prompt}
#       end
#     end
#
# ## Example
#
#     import Support.Factories.Prompt
#
#     module "Full" do
#       prompt "code_review" do
#         title "Code review"
#         description "Reviews code with a focus on safety"
#
#         argument "language", required: true, description: "Programming language"
#         argument "focus", description: "security | performance | style"
#
#         meta "key1", "value1"
#         meta "key2", "value2"
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
# ## Get a single prompt
#
# `compile_one_prompt/1` compiles the module and returns its only declared prompt
# (asserting exactly one was declared).
#
#     import Support.Factories.Prompt
#
#     prompt =
#       module "Single" do
#         prompt "code_review" do
#           title "Code review"
#           description "Reviews code"
#
#           argument "language", required: true
#         end
#       end
#       |> compile_one_prompt()
#
#     assert prompt.arguments == [%OzMcp.Structs.PromptArgument{name: "language", required: true}]
#
# ## Assert raise at compilation time
#
#     import Support.Factories.Prompt
#
#     module "Bad" do
#       prompt "p" do
#         title "First"
#         title "Second"
#       end
#     end
#     |> assert_compile_raise(RuntimeError, "cannot declare 'title' multiple times")
#
# `assert_compile_raise/4` additionally asserts that the captured stderr contains
# the given string. Use it for `CompileError` — in the prompt DSL this happens at
# the module root, where only `prompt/2` is imported so any other macro is an
# undefined function:
#
#     import Support.Factories.Prompt
#
#     module "Bad" do
#       title "root-level"
#     end
#     |> assert_compile_raise(
#       CompileError,
#       ~r"nofile: cannot compile module Support.Generated.Prompt.Bad",
#       "undefined function title/1"
#     )
#
# ## Assert warning at compilation time
#
# Use `assert_compile_warning/2` to assert warning presence:
#
#     import Support.Factories.Prompt
#
#     module "Warn", _warn_: true do
#       prompt "code_review", description: "A prompt"
#     end
#     |> assert_compile_warning("The prompt code_review does not have a title configuration")
#
# Use `refute_compile_warning/2` to refute warnings presence:
#
#     module "NoWarn" do
#       prompt "code_review"
#     end
#     |> refute_compile_warning([
#       "does not have a title configuration",
#       "does not have a description configuration"
#     ])
#
# ## Disabling the DSL
#
# The DSL is activated by default (`use OzMcp.Config.Prompt`). Pass `_dsl_: false` to deactivate
# it. Only `list/0` and `get/2` are required.
#
#     import Support.Factories.Prompt
#
#     code =
#       quote do
#         def list, do: []
#         def get(_ctx, _params), do: {:error, :no_prompt}
#       end
#
#     module("Prompts", _dsl_: false, _code_: code)
#     |> compile()
#
# ## Code injection
#
# `_code_:` injects arbitrary expressions into the generated module. It is mainly
# used to test `__before_compile__/1` collisions, e.g. defining `list/0` while the
# DSL is active:
#
#     import Support.Factories.Prompt
#
#     code =
#       quote do
#         def list(), do: []
#       end
#
#     module("Bad", _code_: code) do
#       prompt "code_review"
#     end
#     |> assert_compile_raise(
#       RuntimeError,
#       "when using the prompt DSL you can't declare list/0 function"
#     )
#
# ## The `get/2` callback
#
# `OzMcp.Config.Prompt` requires a `get/2` callback that the DSL never
# auto-generates. To keep every generated module free of compiler errors,
# Support.Factories.Prompt injects a default `def get(_ctx, _params), do: {:error, :no_prompt}` unless:
#
#   * the injected code already defines `get` (detected through the
#     `_code_` option), or
#   * the auto-injection is disabled with `_get_: :_none_`.
#
# Use `_get_: :_none_` when you want to observe the
# `you must satisfy the get/2 behaviour` compile error, or when you provide
# a custom `get/2` through `_code_`.
#
defmodule Support.Factories.Prompt do
  use Support.Factories.Kit

  def compile_one_prompt(ast) do
    [prompt] = compile(ast).list()
    prompt
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
    use_opts = Support.Factories.Kit.use_opts(opts, _dsl_: :dsl?, _warn_: :warn?)

    get_exprs =
      case Keyword.get(opts, :_get_, :auto) do
        :_none_ -> []
        :auto -> if has_def?(code, :get), do: [], else: [default_get()]
      end

    use_line = use_line(quote(do: OzMcp.Config.Prompt), use_opts)

    quote do
      defmodule unquote(Support.Factories.Kit.unique("Support.Generated.Prompt", name)) do
        (unquote_splicing([use_line] ++ exprs ++ code ++ get_exprs))
      end
    end
  end

  block(:prompt, named: true, lines: [title: :_none_, description: :_none_])

  block(:icon,
    lines: [src: "https://z.net/icon.png", mime_type: :_none_, sizes: :_none_, theme: :_none_]
  )

  props(
    plain: [:title, :description, :src, :mime_type, :theme],
    escaped: [:required_scopes, :sizes],
    keyed: [:meta]
  )

  def argument(name, opts \\ []) do
    quote do: argument(unquote(name), unquote(Macro.escape(opts)))
  end

  defp default_get do
    quote do
      def get(_ctx, _params), do: {:error, :no_prompt}
    end
  end
end
