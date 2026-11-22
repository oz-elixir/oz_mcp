#
# The server factory is a helper module used to generate server configuration modules
# using the DSL.
#
# ## Generate and compile a server configuration module
#
#     import Support.Factories.Server
#
#     config =
#       module "Instructions" do
#         instructions "Use this server to manage marketing assets."
#       end
#       |> compile_config()
#
#     assert config.instructions == "Use this server to manage marketing assets."
#
# ## Generate and get the source code (usefull for debugging)
#
#     import Support.Factories.Server
#
#     source =
#       module "Instructions" do
#         instructions "Use this server to manage marketing assets."
#       end
#       |> source()
#
#     IO.puts(source)
#
# This will generate the following server configuration module:
#
#     defmodule Support.Generated.Server.Instructions_3234 do
#       use OzMcp.Config.Server
#
#       server_info do
#         name("my-server")
#         version("1.0.0")
#       end
#
#       tools do
#         tool(Support.Entities.Tools.SecondTest)
#       end
#
#       instructions("Use this server to manage marketing assets.")
#     end
#
# ## Example
#
#     import Support.Factories.Server
#
#     module "Full" do
#       protocol_version "2025-11-25"
#
#       server_info do
#         title "The title"
#         website_url "https://example.com"
#
#         icon do
#           mime_type "image/png"
#           sizes ["16x16", "32x32"]
#         end
#       end
#
#       capabilities do
#         experimental %{feature: %{}}
#         logging %{}
#         cap_resources(subscribe: true)
#
#         tasks do
#           list %{a: 1}
#         end
#       end
#
#       tools do
#         paginate 10
#
#         list_result do
#           meta "key", "value"
#         end
#       end
#
#       resources do
#         resource Support.Entities.Resources.SecondTest
#       end
#
#       meta "root-key", "root-value"
#     end
#     |> source()
#     |> IO.puts()
#
# This will generate the following server configuration module:
#
#     defmodule Support.Generated.Server.Full_482 do
#       use OzMcp.Config.Server
#
#       server_info do
#         version("1.0.0")
#         name("my-server")
#         title("The title")
#         website_url("https://example.com")
#
#         icon do
#           src("https://z.net/icon.png")
#           mime_type("image/png")
#           sizes(["16x16", "32x32"])
#         end
#       end
#
#       capabilities do
#         experimental(%{feature: %{}})
#         logging(%{})
#
#         resources do
#           subscribe(true)
#         end
#
#         tasks do
#           list(%{a: 1})
#         end
#       end
#
#       tools do
#         tool(Support.Entities.Tools.SecondTest)
#         paginate(10)
#
#         list_result do
#           meta("key", "value")
#         end
#       end
#
#       resources do
#         resource(Support.Entities.Resources.SecondTest)
#       end
#
#       protocol_version("2025-11-25")
#       meta("root-key", "root-value")
#     end
#
# ## Using keyword arguments or code block
#
#     import Support.Factories.Server
#
#     module "Kw" do
#       server_info(name: "kw-server", version: "9.9.9")
#
#       tools(tool: Support.Entities.Tools.FirstTest)
#
#       icon()
#     end
#     |> source()
#     |> IO.puts()
#
# ## Specific tests: auto-injection opt-outs
#
# To test a missing required `server_info`/`tools`/`resources` at the root, or a
# missing required child inside a block, use the `:_none_` opt-out:
#
#     import Support.Factories.Server
#
#     module "NoServerInfo", _server_info_: :_none_ do
#     end
#     |> assert_compile_raise(RuntimeError, "'server_info' is required")
#
#     module "NoTool" do
#       server_info()
#       tools(tool: :_none_)
#     end
#     |> assert_compile_raise(RuntimeError, "must declare at least one tool")
#
#     module "NoName" do
#       server_info(name: :_none_) do
#         version "1.0.0"
#       end
#     end
#     |> assert_compile_raise(RuntimeError, "'name' is required")
#
# To test duplicates, simply declare the property twice:
#
#     import Support.Factories.Server
#
#     module "DuplicateProtocolVersion" do
#       protocol_version "2025-11-25"
#       protocol_version "2025-11-25"
#     end
#     |> assert_compile_raise(RuntimeError, "cannot declare 'protocol_version' multiple times")
#
# ## Get the compiled config
#
# `compile_config/1` compiles the module and returns its `config/0`.
#
#     import Support.Factories.Server
#
#     config =
#       module "Name" do
#         server_info do
#           name "my-server"
#         end
#       end
#       |> compile_config()
#
#     assert config.server_info.name == "my-server"
#
# ## Assert raise at compilation time
#
#     import Support.Factories.Server
#
#     module "Bad" do
#       name "root-level"
#     end
#     |> assert_compile_raise(RuntimeError, "cannot use 'name' here")
#
# `assert_compile_raise/4` additionally asserts that the captured stderr contains
# the given string. Use it for `CompileError`, where the compiler logs the real
# diagnostic to stderr:
#
#     import Support.Factories.Server
#
#     code =
#       quote do
#         def oops(), do: nonexistent()
#       end
#
#     module "Bad", _code_: code, _tools_: :_none_, _resources_: :_none_ do
#       server_info(name: "bad", version: "1.0.0")
#     end
#     |> assert_compile_raise(
#       CompileError,
#       ~r"nofile: cannot compile module Support.Generated.Server.Bad",
#       "undefined function nonexistent/0"
#     )
#
# ## Assert warning at compilation time
#
# Use `assert_compile_warning/2` to assert warning presence:
#
#     import Support.Factories.Server
#
#     code =
#       quote do
#         def f(), do: (x = 1; :ok)
#       end
#
#     module "Warns", _code_: code do
#       server_info(name: "warns", version: "1.0.0")
#     end
#     |> assert_compile_warning("variable \"x\" is unused")
#
# Use `refute_compile_warning/2` to refute warnings presence:
#
#     module "Clean" do
#       server_info(name: "clean", version: "1.0.0")
#     end
#     |> refute_compile_warning(["unused", "warning"])
#
# ## Code injection
#
#     import Support.Factories.Server
#
#     code =
#       quote do
#         def custom(), do: :ok
#       end
#
#     module "WithCode", _code_: code do
#       instructions "x"
#     end
#     |> compile()
#
defmodule Support.Factories.Server do
  use Support.Factories.Kit

  def compile_config(ast) do
    compile(ast).config()
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
    final_exprs =
      exprs
      |> maybe_server_info(opts)
      |> maybe_tools(opts)

    quote do
      defmodule unquote(Support.Factories.Kit.unique("Support.Generated.Server", name)) do
        use OzMcp.Config.Server

        (unquote_splicing(final_exprs ++ code(opts)))
      end
    end
  end

  # A valid server needs a minimal `server_info` block. Auto-inject one
  # unless the test already declares it or opts out with
  # `_server_info_: :_none_`.
  #
  defp maybe_server_info(exprs, opts) do
    cond do
      has_call?(exprs, :server_info) -> exprs
      Keyword.get(opts, :_server_info_, nil) == :_none_ -> exprs
      true -> [__server_info__([], []) | exprs]
    end
  end

  # A valid server needs at least one `tools`, `resources`, `templates` or
  # `prompts` block. Auto-inject a minimal `tools` block unless the test
  # already declares one or opts out with `_tools_: :_none_`.
  #
  defp maybe_tools(exprs, opts) do
    cond do
      Enum.any?([:tools, :resources, :templates, :prompts], &has_call?(exprs, &1)) -> exprs
      Keyword.get(opts, :_tools_, nil) == :_none_ -> exprs
      true -> exprs ++ [__tools__([], [])]
    end
  end

  block(:server_info,
    lines: [
      name: {:required, "my-server"},
      version: {:required, "1.0.0"},
      title: :_none_,
      description: :_none_,
      website_url: :_none_
    ]
  )

  block(:capabilities, lines: [experimental: :_none_, logging: :_none_, completions: :_none_])
  block(:tasks, lines: [list: :_none_, cancel: :_none_, requests: :_none_])
  block(:authorization, lines: [], body: :raw)
  block(:cap_resources, as: :resources, lines: [subscribe: :_none_])
  block(:tools, lines: [tool: {:required, Support.Entities.Tools.SecondTest}])
  block(:prompts, lines: [prompt: {:required, Support.Entities.Prompts.FirstTest}])
  block(:resources, lines: [resource: {:required, Support.Entities.Resources.FirstTest}])
  block(:templates, lines: [template: {:required, Support.Entities.Templates.FirstTest}])
  block(:list_result, lines: [], body: :raw)

  block(:icon,
    lines: [
      src: {:required, "https://z.net/icon.png"},
      mime_type: :_none_,
      sizes: :_none_,
      theme: :_none_
    ]
  )

  props(
    plain: [
      :protocol_version,
      :instructions,
      :name,
      :version,
      :title,
      :description,
      :website_url,
      :paginate,
      :subscribe,
      :verifier,
      :authorization_servers,
      :scopes_supported,
      :challenge_scopes,
      :filter_by_scope,
      :audience_check,
      :resource_name,
      :resource_documentation,
      :tool,
      :prompt,
      :resource,
      :template,
      :src,
      :mime_type,
      :sizes,
      :theme
    ],
    escaped: [:experimental, :logging, :completions, :list, :cancel, :requests],
    keyed: [:meta, :extra]
  )
end
