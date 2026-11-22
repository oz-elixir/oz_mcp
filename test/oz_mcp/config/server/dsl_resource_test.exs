#
# Tests for the `resource/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLResourceTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "resource/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a module atom inside resources block" do
      config =
        module("Resource") do
          resources(resource: Support.Entities.Resources.FirstTest)
        end
        |> compile_config()

      assert config.resources.modules == [Support.Entities.Resources.FirstTest]
    end

    test "accepts multiple resources accumulating in declaration order" do
      config =
        module("Resource") do
          resources do
            resource Support.Entities.Resources.FirstTest
            resource Support.Entities.Resources.SecondTest
          end
        end
        |> compile_config()

      assert config.resources.modules == [
               Support.Entities.Resources.FirstTest,
               Support.Entities.Resources.SecondTest
             ]
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when the same module is listed two times in resources" do
      module("Resource") do
        resources do
          resource Support.Entities.Resources.FirstTest
          resource Support.Entities.Resources.FirstTest
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "module #{inspect(Support.Entities.Resources.FirstTest)} is listed two times in 'resources'"
      )
    end

    test "raises when resource is not a module" do
      module("Resource") do
        resources(resource: "not-a-module")
      end
      |> assert_compile_raise(
        ArgumentError,
        "'resource' must be a module (atom), got: \"not-a-module\""
      )
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises resource cannot be at root level" do
      module("Resource") do
        resource Support.Entities.Resources.FirstTest
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Resource",
        "undefined function resource/1"
      )
    end

    test "raises when resource is used inside tools block" do
      module("Resource") do
        tools do
          resource Support.Entities.Resources.FirstTest
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'resource' here")
    end
  end
end
