#
# Tests for the `__using__/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
# NOTE: this file is intentionally NOT refactored to use Support.Factories.Server. It tests
# the raw `use OzMcp.Config.Server.DSL` `__using__/1` macro directly. Support.Factories.Server
# always emits the higher-level `use OzMcp.Config.Server` wrapper, so it cannot
# express assertions about the raw DSL module's `__using__`.
#
defmodule OzMcp.Config.Server.DSLUsingTest do
  use ExUnit.Case, async: true

  describe "__using__/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts use OzMcp.Config.Server.DSL with no option" do
      code = """
      defmodule Support.Servers.UsingNoOption do
        use OzMcp.Config.Server.DSL

        server_info do
          name "using-no-option"
          version "1.0.0"
        end

        tools do
          tool Support.Entities.Tools.SecondTest
        end
      end
      """

      [{mod, _}] = Code.compile_string(code)
      assert mod.config().server_info.name == "using-no-option"
    end
  end

  describe "imports" do
    test "the DSL still defines all its macros" do
      macros = OzMcp.Config.Server.DSL.__info__(:macros)

      for name <-
            ~w(name version title description website_url src mime_type sizes theme paginate
               tool resource template prompt subscribe experimental logging
               completions list cancel requests verifier authorization_servers scopes_supported
               challenge_scopes filter_by_scope resource_name resource_documentation)a do
        assert {name, 1} in macros
      end
    end

    test "a user module imports only the root macros" do
      code = """
      defmodule Support.Servers.UsingImports do
        use OzMcp.Config.Server.DSL

        @imported_macros __ENV__.macros()

        def imported_macros, do: @imported_macros

        server_info do
          name "using-imports"
          version "1.0.0"
        end

        tools do
          tool Support.Entities.Tools.SecondTest
        end
      end
      """

      [{mod, _}] = Code.compile_string(code)

      imported =
        mod.imported_macros()
        |> Keyword.get(OzMcp.Config.Server.DSL, [])
        |> Enum.sort()

      assert imported == [
               authorization: 1,
               capabilities: 1,
               extra: 2,
               instructions: 1,
               meta: 2,
               prompts: 1,
               protocol_version: 1,
               resources: 1,
               server_info: 1,
               templates: 1,
               tools: 1
             ]
    end

    test "a server module can define and call a local name/1 function" do
      code = """
      defmodule Support.Servers.LocalName do
        use OzMcp.Config.Server

        def name(x), do: x

        def call_local_name(), do: name(1)

        server_info do
          name "local-name-server"
          version "1.0.0"
        end

        tools do
          tool Support.Entities.Tools.SecondTest
        end
      end
      """

      [{mod, _}] = Code.compile_string(code)

      assert mod.call_local_name() == 1
      assert mod.config().server_info.name == "local-name-server"
    end

    test "a server module can define a local list/1 function and still declare tasks list" do
      code = """
      defmodule Support.Servers.LocalList do
        use OzMcp.Config.Server

        def list(x), do: x

        def call_local_list(), do: list(:local)

        server_info do
          name "local-list-server"
          version "1.0.0"
        end

        capabilities do
          tasks do
            list %{enabled: true}
          end
        end

        tools do
          tool Support.Entities.Tools.SecondTest
        end
      end
      """

      [{mod, _}] = Code.compile_string(code)

      assert mod.call_local_list() == :local
      assert mod.config().capabilities.tasks.list == %{enabled: true}
    end
  end
end
