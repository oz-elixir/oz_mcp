#
# Tests for the `template/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLTemplateTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "template/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a module atom inside templates block" do
      config =
        module("Template") do
          templates(template: Support.Entities.Templates.FirstTest)
        end
        |> compile_config()

      assert config.templates.modules == [Support.Entities.Templates.FirstTest]
    end

    test "accepts multiple templates accumulating in declaration order" do
      config =
        module("Template") do
          templates do
            template Support.Entities.Templates.FirstTest
            template Support.Entities.Templates.SecondTest
          end
        end
        |> compile_config()

      assert config.templates.modules == [
               Support.Entities.Templates.FirstTest,
               Support.Entities.Templates.SecondTest
             ]
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when the same module is listed two times in templates" do
      module("Template") do
        templates do
          template Support.Entities.Templates.FirstTest
          template Support.Entities.Templates.FirstTest
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "module #{inspect(Support.Entities.Templates.FirstTest)} is listed two times in 'templates'"
      )
    end

    test "accepts the same module in resources and in templates" do
      config =
        module("SameAtom") do
          resources do
            resource Support.Entities.Resources.FirstTest
          end

          templates do
            template Support.Entities.Resources.FirstTest
          end
        end
        |> compile_config()

      assert config.resources.modules == [Support.Entities.Resources.FirstTest]
      assert config.templates.modules == [Support.Entities.Resources.FirstTest]
    end

    test "raises when template is not a module" do
      module("Template") do
        templates(template: "not-a-module")
      end
      |> assert_compile_raise(
        ArgumentError,
        "'template' must be a module (atom), got: \"not-a-module\""
      )
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises template cannot be at root level" do
      module("Template") do
        template Support.Entities.Templates.FirstTest
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Template",
        "undefined function template/1"
      )
    end

    test "raises when template is used inside tools block" do
      module("Template") do
        tools do
          template Support.Entities.Templates.FirstTest
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'template' here")
    end

    test "raises when template is used inside resources block" do
      module("Template") do
        resources do
          template Support.Entities.Templates.FirstTest
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'template' here")
    end
  end
end
