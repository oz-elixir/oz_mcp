#
# Tests for the `templates/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLTemplatesTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "templates/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a templates block with at least one template" do
      config =
        module("Templates") do
          templates()
        end
        |> compile_config()

      assert config.templates.modules == [Support.Entities.Templates.FirstTest]
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when templates block is empty" do
      module("Templates") do
        templates(template: :_none_)
      end
      |> assert_compile_raise(RuntimeError, "must declare at least one template")
    end

    test "raises when templates is declared multiple times" do
      module("Templates") do
        templates(template: Support.Entities.Templates.FirstTest)
        templates(template: Support.Entities.Templates.FirstTest)
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'templates' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when templates is used inside tools block" do
      module("Templates") do
        tools do
          templates(template: Support.Entities.Templates.FirstTest)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'templates' here")
    end

    test "raises when templates is used inside resources block" do
      module("Templates") do
        resources do
          templates(template: Support.Entities.Templates.FirstTest)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'templates' here")
    end

    test "raises when templates is used inside capabilities block" do
      module("Templates") do
        capabilities do
          templates(template: Support.Entities.Templates.FirstTest)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'templates' here")
    end
  end
end
