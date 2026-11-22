#
# The template factory is a helper module used to generate template configuration modules
# using the DSL.
#
# ## Generate and compile a template configuration module
#
#     import Support.Factories.Template
#
#     module =
#       module "Archives" do
#         template "doc"
#       end
#       |> compile()
#
#     module.list()
#
# ## Generate and get the source code (usefull for debugging)
#
#     import Support.Factories.Template
#
#     source =
#       module "Archives" do
#         template "doc"
#       end
#       |> source()
#
#     IO.puts(source)
#
# ## Enabling/Disabling warning
#
# By default the template module is generated with warning set to `false`.
#
# When testing warnings you can set it to `true`:
#
#     import Support.Factories.Template
#
#     module "Using", _warn_: true do
#       template "doc"
#     end
#     |> source()
#     |> IO.puts()
#
# This will generate the following template configuration module:
#
#     defmodule Support.Generated.Template.Using_3234 do
#       use OzMcp.Config.Template, warn?: true
#
#       template("doc") do
#         uri_template("file:///doc/{path}")
#       end
#     end
#
# To test the default value of warn option:
#
#     import Support.Factories.Template
#
#     module "Using", _warn_: _none_ do
#       template "doc"
#     end
#     |> source()
#     |> IO.puts()
#
# This will generate the following template configuration module:
#
#     defmodule Support.Generated.Template.Using_3234 do
#       use OzMcp.Config.Template
#
#       template("doc") do
#         uri_template("file:///doc/{path}")
#       end
#     end
#
# ## Example
#
#     import Support.Factories.Template
#
#     module "Archives" do
#       template "Archives" do
#         title "Company archives"
#         description "All company archives files"
#         annotations do
#           audience ["user"]
#         end
#       end
#     end
#     |> source()
#     |> IO.puts()
#
# This will generate the following template configuration module:
#
#     defmodule Support.Generated.Template.Archives_482 do
#       use OzMcp.Config.Template, warn?: false
#
#       template("Archives") do
#         uri_template("file:///Archives/{path}")
#         title("Company archives")
#         description("All company archives files")
#
#         annotations do
#           audience(["user"])
#         end
#       end
#     end
#
# ## Using keyword arguments or code block
#
#     import Support.Factories.Template
#
#     module "Archives" do
#       template "doc" do
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
# This will generate the following template configuration module:
#
#     defmodule Support.Generated.Template.Archives_1602 do
#       use OzMcp.Config.Template, warn?: false
#
#       template("doc") do
#         uri_template("file:///doc/{path}")
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
#     end
#
# ## Specific tests
#
# To test empty block, required properties or duplicates:
#
#     import Support.Factories.Template
#
#     module "Archives" do
#       # Auto-generate a simplest valid template (auto-add the required uri_template).
#       template "doc" do
#       end
#
#       # Don't auto-generate the uri_template properties (used to test empty block).
#       template "doc", uri_template: :_none_
#
#       # Set specific uri_template
#       template "doc", uri_template: "file://docs/doc"
#
#       # Used to test duplicates uri_template declaration.
#       template "doc" do
#         uri_template "file://docs/duplicate"
#       end
#     end
#     |> source()
#     |> IO.puts()
#
# This will generate the following template configuration module:
#
#     defmodule Support.Generated.Template.Archives_1346 do
#       use OzMcp.Config.Template, warn?: false
#
#       template("doc") do
#         uri_template("file:///doc/{path}")
#       end
#
#       template("doc") do
#       end
#
#       template("doc") do
#         uri_template("file://docs/doc")
#       end
#
#       template("doc") do
#         uri_template("file:///doc/{path}")
#         uri_template("file://docs/duplicate")
#       end
#     end
#
# ## Get a single template
#
# `compile_one_template/1` compiles the module and returns its only declared
# template (asserting exactly one was declared).
#
#     import Support.Factories.Template
#
#     template =
#       module "Archives" do
#         template "doc" do
#           annotations(audience: ["user"])
#         end
#       end
#       |> compile_one_template()
#
#     assert template.annotations.audience == ["user"]
#
# ## Assert raise at compilation time
#
#     import Support.Factories.Template
#
#     module "Archives" do
#       audience ["user"]
#     end
#     |> assert_compile_raise(RuntimeError, "cannot use 'audience' here")
#
# `assert_compile_raise/4` additionally asserts that the captured stderr contains
# the given string. Use it for `CompileError` — in the template DSL this happens
# at the module root, where only `template/2` is imported so any other macro is
# an undefined function:
#
#     import Support.Factories.Template
#
#     module "Bad" do
#       title "root-level"
#     end
#     |> assert_compile_raise(
#       CompileError,
#       ~r"nofile: cannot compile module Support.Generated.Template.Bad",
#       "undefined function title/1"
#     )
#
# The 4th arg also works for arbitrary injected code that fails to compile:
#
#     import Support.Factories.Template
#
#     code =
#       quote do
#         def oops(), do: nonexistent()
#       end
#
#     module "Bad", _code_: code do
#       template "doc"
#     end
#     |> assert_compile_raise(
#       CompileError,
#       ~r"nofile: cannot compile module Support.Generated.Template.Bad",
#       "undefined function nonexistent/0"
#     )
#
# ## Assert warning at compilation time
#
# Use `assert_compile_warning/2` to assert warning presence:
#
#     import Support.Factories.Template
#
#     module "Warn", _warn_: true do
#       template "doc", description: "A doc"
#     end
#     |> assert_compile_warning("The template doc does not have a title configuration")
#
# Use `refute_compile_warning/2` to refute warnings presence:
#
#     module "NoWarn" do
#       template "doc"
#     end
#     |> refute_compile_warning([
#       "does not have a title configuration",
#       "does not have a description configuration"
#     ])
#
# ## Disabling the DSL
#
# The DSL is activated by default (`use OzMcp.Config.Template`). Pass `_dsl_: false`
# to deactivate it. Only `list/0` is required.
#
#     import Support.Factories.Template
#
#     code =
#       quote do
#         def list(), do: []
#       end
#
#     module("Archives", _dsl_: false, _code_: code)
#     |> compile()
#
# ## Code injection
#
# `_code_:` injects arbitrary expressions into the generated module. It is mainly
# used to test `__before_compile__/1` collisions, e.g. defining `list/0` while the
# DSL is active:
#
#     import Support.Factories.Template
#
#     code =
#       quote do
#         def list(), do: []
#       end
#
#     module("Bad", _code_: code) do
#       template "doc"
#     end
#     |> assert_compile_raise(
#       RuntimeError,
#       "when using the template DSL you can't declare list/0 function"
#     )
#
# > `read/3` is a required behaviour callback that the DSL does not generate.
# > The factory always injects a `read/3` stub so built modules stay conformant.
#
defmodule Support.Factories.Template do
  use Support.Factories.Kit

  def compile_one_template(ast) do
    [template] = compile(ast).list()
    template
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
    use_line =
      use_line(
        quote(do: OzMcp.Config.Template),
        Support.Factories.Kit.use_opts(opts, _dsl_: :dsl?, _warn_: :warn?)
      )

    # `read/4` is a required behaviour callback (not generated by the DSL).
    # Injecting a stub keeps factory-built modules conformant.
    #
    read_line =
      quote(do: def(read(_ctx, _rpc_params, _uri_template, _uri_params), do: {:ok, %{}}))

    quote do
      defmodule unquote(Support.Factories.Kit.unique("Support.Generated.Template", name)) do
        (unquote_splicing([use_line] ++ exprs ++ code(opts) ++ [read_line]))
      end
    end
  end

  block(:template, named: true)

  @doc false
  def __template__(name, opts, exprs) do
    lines =
      Support.Factories.Kit.lines(
        __MODULE__,
        opts,
        [
          uri_template: "file:///#{name}/{path}",
          title: :_none_,
          description: :_none_,
          mime_type: :_none_
        ],
        exprs
      )

    Support.Factories.Kit.node(:template, [name], lines ++ exprs, false)
  end

  block(:annotations, lines: [audience: :_none_, priority: :_none_, last_modified: :_none_])

  block(:icon,
    lines: [src: "https://z.net/icon.png", mime_type: :_none_, sizes: :_none_, theme: :_none_]
  )

  props(
    plain: [
      :uri_template,
      :title,
      :description,
      :mime_type,
      :src,
      :sizes,
      :theme,
      :audience,
      :priority,
      :last_modified
    ],
    escaped: [:required_scopes],
    keyed: [:meta]
  )
end
