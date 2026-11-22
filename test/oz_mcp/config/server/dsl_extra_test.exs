#
# Tests for the `extra/2` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLExtraTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "extra/2" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a string key and string value" do
      config =
        module("Extra") do
          extra "key", "value"
        end
        |> compile_config()

      assert config.extras == %{"key" => "value"}
    end

    test "accepts multiple extra entries" do
      config =
        module("Extra") do
          extra "key1", "value1"
          extra "key2", "value2"
        end
        |> compile_config()

      assert config.extras == %{"key1" => "value1", "key2" => "value2"}
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when extra key is not a string" do
      module("Extra") do
        extra 123, "value"
      end
      |> assert_compile_raise(ArgumentError, "'key' must be a string, got: 123")
    end

    test "raises when extra key already exists" do
      module("Extra") do
        extra "key", "first"
        extra "key", "second"
      end
      |> assert_compile_raise(RuntimeError, "key 'key' already exists")
    end

    test "raises when extra key is a field of the root result" do
      module("Extra") do
        extra "protocolVersion", "x"
      end
      |> assert_compile_raise(
        ArgumentError,
        "'extra' key \"protocolVersion\" is a field of the result, " <>
          "use the field (or 'meta' for \"_meta\")"
      )
    end

    test "raises for a reserved key given as an atom" do
      module("Extra") do
        extra :capabilities, "x"
      end
      |> assert_compile_raise(
        ArgumentError,
        "'extra' key \"capabilities\" is a field of the result, " <>
          "use the field (or 'meta' for \"_meta\")"
      )
    end

    test "raises when extra key is _meta and the message names meta" do
      module("Extra") do
        extra "_meta", nil
      end
      |> assert_compile_raise(
        ArgumentError,
        "'extra' key \"_meta\" is a field of the result, use the field (or 'meta' for \"_meta\")"
      )
    end

    # -----------------------------------------------------------------------
    # Special
    # -----------------------------------------------------------------------

    test "extra converts atom key to string" do
      config =
        module("Extra") do
          extra :my_key, "my_value"
        end
        |> compile_config()

      assert config.extras == %{"my_key" => "my_value"}
    end

    test "extra converts atom value to string" do
      config =
        module("Extra") do
          extra "my_key", :my_value
        end
        |> compile_config()

      assert config.extras == %{"my_key" => "my_value"}
    end

    test "extra keeps true as boolean" do
      config =
        module("Extra") do
          extra "beta", true
        end
        |> compile_config()

      assert config.extras == %{"beta" => true}
    end

    test "extra keeps false as boolean" do
      config =
        module("Extra") do
          extra "beta", false
        end
        |> compile_config()

      assert config.extras == %{"beta" => false}
    end

    test "extra keeps nil as null" do
      config =
        module("Extra") do
          extra "beta", nil
        end
        |> compile_config()

      assert config.extras == %{"beta" => nil}
    end

    test "raises when extra key is nil" do
      module("Extra") do
        extra nil, "value"
      end
      |> assert_compile_raise(ArgumentError, "'key' must be a string, got: nil")
    end

    # -----------------------------------------------------------------------
    # Accepts (prompts)
    # -----------------------------------------------------------------------

    test "accepts extra entries inside prompts > list_result block" do
      config =
        module("Extra") do
          prompts do
            list_result do
              extra "key", "value"
            end
          end
        end
        |> compile_config()

      assert config.prompts.list_result == %{_meta: nil, extras: %{"key" => "value"}}
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when extra is used inside tools block" do
      module("Extra") do
        tools do
          extra "key", "value"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'extra' here")
    end
  end
end
