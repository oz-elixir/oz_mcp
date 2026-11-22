#
# The resource factory is a helper module used to generate resource configuration modules
# using the DSL.
#
# ## Generate and compile a resource configuration module
#
#     import Support.Factories.Resource
#
#     module =
#       module "Audience" do
#         resource "doc.md"
#       end
#       |> compile()
#
#     module.list_resource()
#
# ## Generate and get the source code (usefull for debugging)
#
#     import Support.Factories.Resource
#
#     source =
#       module "Audience" do
#         resource "doc.md"
#       end
#       |> source()
#
#     IO.puts(source)
#
# ## Enabling/Disabling warning
#
# By default the resource module is generated with warning set to `false`.
#
# When testing warnings you can set it to `true`:
#
#     import Support.Factories.Resource
#
#     module "Using", _warn_: true do
#       resource "doc.md"
#     end
#     |> source()
#     |> IO.puts()
#
# This will generate the following resource configuration module:
#
#     defmodule Support.Generated.Resource.Using_3234 do
#       use OzMcp.Config.Resource, warn?: true
#
#       resource("doc.md") do
#         uri("file:///doc.md")
#       end
#     end
#
# To test the default value of warn option:
#
#     import Support.Factories.Resource
#
#     module "Using", _warn_: _none_ do
#       resource "doc.md"
#     end
#     |> source()
#     |> IO.puts()
#
# This will generate the following resource configuration module:
#
#     defmodule Support.Generated.Resource.Using_3234 do
#       use OzMcp.Config.Resource
#
#       resource("doc.md") do
#         uri("file:///doc.md")
#       end
#     end
#
# ## Example
#
#     import Support.Factories.Resource
#
#     module "Audience" do
#       resource "doc.md" do
#         title "ok"
#         description "coolos"
#         icon do
#           mime_type "image/png"
#           sizes ["32x32", "64x64"]
#         end
#         meta "key1", "value1"
#       end
#     end
#     |> source()
#     |> IO.puts()
#
# This will generate the following resource configuration module:
#
#     defmodule Support.Generated.Resource.Audience_482 do
#       use OzMcp.Config.Resource, warn?: false
#
#       resource("doc.md") do
#         uri("file:///doc.md")
#         title("ok")
#         description("coolos")
#
#         icon do
#           src("https://z.net/icon.png")
#           mime_type("image/png")
#           sizes(["32x32", "64x64"])
#         end
#
#         meta("key1", "value1")
#       end
#     end
#
# ## Using keyword arguments or code block
#
#     import Support.Factories.Resource
#
#     module "Audience" do
#       resource "doc.md" do
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
# This will generate the following resource configuration module:
#
#     defmodule Support.Generated.Resource.Audience_1602 do
#       use OzMcp.Config.Resource, warn?: false
#
#       resource("doc.md") do
#         uri("file:///doc.md")
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
#     import Support.Factories.Resource
#
#     module "Audience" do
#       # Auto-generate a simplest valid resource (auto-add the required uri).
#       resource "doc.md" do
#       end
#
#       # Don't auto-generate the uri properties (used to test empty block).
#       resource "doc.md", uri: :_none_
#
#       # Set specific uri
#       resource "doc.md", uri: "https://z.dev/doc.md"
#
#       # Used to test duplicates uri declaration.
#       resource "doc.md" do
#         uri "https://err.net/duplicate.md"
#       end
#     end
#     |> source()
#     |> IO.puts()
#
# This will generate the following resource configuration module:
#
#     defmodule Support.Generated.Resource.Audience_1346 do
#       use OzMcp.Config.Resource, warn?: false
#
#       resource("doc.md") do
#         uri("file:///doc.md")
#       end
#
#       resource("doc.md") do
#       end
#
#       resource("doc.md") do
#         uri("https://z.dev/doc.md")
#       end
#
#       resource("doc.md") do
#         uri("file:///doc.md")
#         uri("https://err.net/duplicate.md")
#       end
#     end
#
# ## Get a single resource
#
# `compile_one_resource/1` compiles the module and returns its only declared
# resource (asserting exactly one was declared).
#
#     import Support.Factories.Resource
#
#     resource =
#       module "Audience" do
#         resource "doc.md" do
#           annotations(audience: ["user"])
#         end
#       end
#       |> compile_one_resource()
#
#     assert resource.annotations.audience == ["user"]
#
# ## Assert raise at compilation time
#
#     import Support.Factories.Resource
#
#     module "Audience" do
#       audience ["user"]
#     end
#     |> assert_compile_raise(RuntimeError, "cannot use 'audience' here")
#
# `assert_compile_raise/4` additionally asserts that the captured stderr contains
# the given string. Use it for `CompileError`, where the compiler logs the real
# diagnostic to stderr:
#
#     import Support.Factories.Resource
#
#     code =
#       quote do
#         def oops(), do: nonexistent()
#       end
#
#     module "Bad", _code_: code do
#       resource "doc.md"
#     end
#     |> assert_compile_raise(
#       CompileError,
#       ~r"nofile: cannot compile module Support.Generated.Resource.Bad",
#       "undefined function nonexistent/0"
#     )
#
# ## Assert warning at compilation time
#
# Use `assert_compile_warning/2` to assert warning presence:
#
#     import Support.Factories.Resource
#
#     module "Warn", _warn_: true do
#       resource "doc.md", description: "A doc"
#     end
#     |> assert_compile_warning("The resource doc.md does not have a title configuration")
#
# Use `refute_compile_warning/2` to refute warnings presence:
#
#     module "NoWarn" do
#       resource "doc.md"
#     end
#     |> refute_compile_warning([
#       "does not have a title configuration",
#       "does not have a description configuration"
#     ])
#
# ## Disabling the DSL
#
# The DSL is activated by default (`use OzMcp.Config.Resource`). Pass `_dsl_: false`
# to deactivate it. Only `list/0` is required.
#
#     import Support.Factories.Resource
#
#     code =
#       quote do
#         def list(), do: []
#       end
#
#     module("Audience", _dsl_: false, _code_: code)
#     |> compile()
#
# ## Code injection
#
# `_code_:` injects arbitrary expressions into the generated module. It is mainly
# used to test `__before_compile__/1` collisions, e.g. defining `list/0` while the
# DSL is active:
#
#     import Support.Factories.Resource
#
#     code =
#       quote do
#         def list(), do: []
#       end
#
#     module("Bad", _code_: code) do
#       resource "doc.md"
#     end
#     |> assert_compile_raise(
#       RuntimeError,
#       "when using the resource DSL you can't declare list/0 function"
#     )
#
# > `read/1` is a required behaviour callback that the DSL does not generate.
# > The factory always injects a `read/1` stub so built modules stay conformant.
#
defmodule Support.Factories.Resource do
  use Support.Factories.Kit

  def compile_one_resource(ast) do
    [resource] = compile(ast).list()
    resource
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
        quote(do: OzMcp.Config.Resource),
        Support.Factories.Kit.use_opts(opts, _dsl_: :dsl?, _warn_: :warn?)
      )

    # `read/2` is a required behaviour callback (not generated by the DSL).
    # Injecting a stub keeps factory-built modules conformant.
    #
    read_line = quote(do: def(read(_ctx, _rpc_params), do: {:ok, %{}}))

    quote do
      defmodule unquote(Support.Factories.Kit.unique("Support.Generated.Resource", name)) do
        (unquote_splicing([use_line] ++ exprs ++ code(opts) ++ [read_line]))
      end
    end
  end

  block(:resource, named: true)

  @doc false
  def __resource__(name, opts, exprs) do
    lines =
      Support.Factories.Kit.lines(
        __MODULE__,
        opts,
        [
          uri: "file:///#{name}",
          title: :_none_,
          description: :_none_,
          mime_type: :_none_,
          size: :_none_
        ],
        exprs
      )

    Support.Factories.Kit.node(:resource, [name], lines ++ exprs, false)
  end

  block(:annotations, lines: [audience: :_none_, priority: :_none_, last_modified: :_none_])

  block(:icon,
    lines: [src: "https://z.net/icon.png", mime_type: :_none_, sizes: :_none_, theme: :_none_]
  )

  props(
    plain: [
      :uri,
      :title,
      :description,
      :mime_type,
      :size,
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
