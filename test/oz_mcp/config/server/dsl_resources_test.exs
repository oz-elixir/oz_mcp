#
# Tests for the `resources/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLResourcesTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "resources/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a resources block with at least one resource" do
      config =
        module("Resources") do
          resources()
        end
        |> compile_config()

      assert config.resources.modules == [Support.Entities.Resources.FirstTest]
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when resources block is empty" do
      module("Resources") do
        resources(resource: :_none_)
      end
      |> assert_compile_raise(RuntimeError, "must declare at least one resource")
    end

    test "raises when resources is declared multiple times" do
      module("Resources") do
        resources(resource: Support.Entities.Resources.FirstTest)
        resources(resource: Support.Entities.Resources.SecondTest)
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'resources' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when resources is used inside tools block" do
      module("Resources") do
        tools do
          resources(resource: Support.Entities.Resources.FirstTest)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'resources' here")
    end

    test "accepts resources as a capabilities sub-block" do
      config =
        module("Resources") do
          resources()

          capabilities do
            cap_resources(subscribe: true)
          end
        end
        |> compile_config()

      assert config.capabilities.resources == %{subscribe: true}
    end
  end
end
