#
# Tests for the `subscribe/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLSubscribeTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "subscribe/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts true inside capabilities > resources block" do
      config =
        module("Subscribe") do
          resources()

          capabilities do
            cap_resources(subscribe: true)
          end
        end
        |> compile_config()

      assert config.capabilities.resources == %{subscribe: true}
    end

    test "accepts false inside capabilities > resources block" do
      config =
        module("Subscribe") do
          resources()

          capabilities do
            cap_resources(subscribe: false)
          end
        end
        |> compile_config()

      assert config.capabilities.resources == %{}
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when subscribe is not a boolean" do
      module("Subscribe") do
        capabilities do
          cap_resources(subscribe: "yes")
        end
      end
      |> assert_compile_raise(ArgumentError, "'subscribe' must be a boolean, got: \"yes\"")
    end

    test "raises when subscribe is used multiple times inside capabilities > resources block" do
      module("Subscribe") do
        capabilities do
          cap_resources do
            subscribe true
            subscribe false
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'subscribe' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises subscribe cannot be at root level" do
      module("Subscribe") do
        subscribe true
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Subscribe",
        "undefined function subscribe/1"
      )
    end

    test "raises when subscribe is used inside root resources block" do
      module("Subscribe") do
        resources do
          subscribe true
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'subscribe' here")
    end
  end
end
