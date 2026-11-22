#
# Tests for the `paginate/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLPaginateTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "paginate/1" do
    # -----------------------------------------------------------------------
    # Accepts (tools)
    # -----------------------------------------------------------------------

    test "accepts a positive integer inside tools block" do
      config =
        module("Paginate") do
          tools do
            paginate 10
          end
        end
        |> compile_config()

      assert config.tools.paginate == 10
    end

    test "raises on zero inside tools block" do
      module("Paginate") do
        tools do
          paginate 0
        end
      end
      |> assert_compile_raise(ArgumentError, "'paginate' must be a positive integer, got: 0")
    end

    test "raises on negative integer inside tools block" do
      module("Paginate") do
        tools do
          paginate -4
        end
      end
      |> assert_compile_raise(ArgumentError, "'paginate' must be a positive integer, got: -4")
    end

    # -----------------------------------------------------------------------
    # Accepts (resources)
    # -----------------------------------------------------------------------

    test "accepts a positive integer inside resources block" do
      config =
        module("Paginate") do
          resources do
            paginate 20
          end
        end
        |> compile_config()

      assert config.resources.paginate == 20
    end

    test "raises on zero inside resources block" do
      module("Paginate") do
        resources do
          paginate 0
        end
      end
      |> assert_compile_raise(ArgumentError, "'paginate' must be a positive integer, got: 0")
    end

    # -----------------------------------------------------------------------
    # Accepts (templates)
    # -----------------------------------------------------------------------

    test "accepts a positive integer inside templates block" do
      config =
        module("Paginate") do
          templates do
            paginate 30
          end
        end
        |> compile_config()

      assert config.templates.paginate == 30
    end

    test "raises on zero inside templates block" do
      module("Paginate") do
        templates do
          paginate 0
        end
      end
      |> assert_compile_raise(ArgumentError, "'paginate' must be a positive integer, got: 0")
    end

    # -----------------------------------------------------------------------
    # Accepts (prompts)
    # -----------------------------------------------------------------------

    test "accepts a positive integer inside prompts block" do
      config =
        module("Paginate") do
          prompts do
            paginate 40
          end
        end
        |> compile_config()

      assert config.prompts.paginate == 40
    end

    test "raises on zero inside prompts block" do
      module("Paginate") do
        prompts do
          paginate 0
        end
      end
      |> assert_compile_raise(ArgumentError, "'paginate' must be a positive integer, got: 0")
    end

    test "raises when paginate is used multiple times inside prompts block" do
      module("Paginate") do
        prompts do
          paginate 10
          paginate 20
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'paginate' multiple times")
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when paginate is not an integer" do
      module("Paginate") do
        tools do
          paginate 10.0
        end
      end
      |> assert_compile_raise(ArgumentError, "'paginate' must be a positive integer, got: 10.0")
    end

    test "raises when paginate is used multiple times inside tools block" do
      module("Paginate") do
        tools do
          paginate 10
          paginate 20
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'paginate' multiple times")
    end

    test "raises when paginate is used multiple times inside resources block" do
      module("Paginate") do
        resources do
          paginate 10
          paginate 20
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'paginate' multiple times")
    end

    test "raises when paginate is used multiple times inside templates block" do
      module("Paginate") do
        templates do
          paginate 10
          paginate 20
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'paginate' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when paginate is used at root level" do
      module("Paginate") do
        paginate 10
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Paginate",
        "undefined function paginate/1"
      )
    end

    test "raises when paginate is used inside capabilities block" do
      module("Paginate") do
        capabilities do
          paginate 10
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'paginate' here")
    end

    test "raises when paginate is used inside server_info block" do
      module("Paginate") do
        server_info do
          paginate 10
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'paginate' here")
    end
  end
end
