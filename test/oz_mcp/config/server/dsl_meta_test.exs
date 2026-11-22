#
# Tests for the `meta/2` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLMetaTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  alias Support.Helpers.Utils

  describe "meta/2" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a string key and string value" do
      config =
        module("Meta") do
          meta "key", "value"
        end
        |> compile_config()

      assert config._meta == %{"key" => "value"}
    end

    test "accepts multiple meta entries" do
      config =
        module("Meta") do
          meta "key1", "value1"
          meta "key2", "value2"
        end
        |> compile_config()

      assert config._meta == %{"key1" => "value1", "key2" => "value2"}
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when meta key is not a string" do
      module("Meta") do
        meta 123, "value"
      end
      |> assert_compile_raise(ArgumentError, "'key' must be a string, got: 123")
    end

    test "raises when meta key already exists" do
      module("Meta") do
        meta "key", "first"
        meta "key", "second"
      end
      |> assert_compile_raise(RuntimeError, "key 'key' already exists")
    end

    test "raises when meta key is not a valid _meta name" do
      module("Meta") do
        meta "a b", "value"
      end
      |> assert_compile_raise(ArgumentError, "bad _meta key \"a b\": bad name")
    end

    test "raises when meta key has a reserved prefix" do
      module("Meta") do
        meta "dev.mcp/x", "value"
      end
      |> assert_compile_raise(ArgumentError, "the _meta prefix of \"dev.mcp/x\" is reserved")
    end

    test "accepts a meta key with a non-reserved prefix" do
      config =
        module("Meta") do
          meta "com.example/key", "value"
        end
        |> compile_config()

      assert config._meta == %{"com.example/key" => "value"}
    end

    # -----------------------------------------------------------------------
    # Special
    # -----------------------------------------------------------------------

    test "meta converts atom key to string" do
      config =
        module("Meta") do
          meta :my_key, "my_value"
        end
        |> compile_config()

      assert config._meta == %{"my_key" => "my_value"}
    end

    test "meta converts atom value to string" do
      config =
        module("Meta") do
          meta "my_key", :my_value
        end
        |> compile_config()

      assert config._meta == %{"my_key" => "my_value"}
    end

    test "meta keeps true as boolean" do
      config =
        module("Meta") do
          meta "beta", true
        end
        |> compile_config()

      assert config._meta == %{"beta" => true}
    end

    test "meta keeps false as boolean" do
      config =
        module("Meta") do
          meta "beta", false
        end
        |> compile_config()

      assert config._meta == %{"beta" => false}
    end

    test "meta keeps nil as null" do
      config =
        module("Meta") do
          meta "beta", nil
        end
        |> compile_config()

      assert config._meta == %{"beta" => nil}
    end

    test "raises when meta key is nil" do
      module("Meta") do
        meta nil, "value"
      end
      |> assert_compile_raise(ArgumentError, "'key' must be a string, got: nil")
    end

    test "initialize_result encodes a boolean meta value as JSON true" do
      server =
        module("Meta") do
          meta "beta", true
        end
        |> compile()

      assert %{_meta: %{"beta" => true}} = server.initialize_result()
      assert Utils.encode_json(server.initialize_result()) =~ "\"beta\":true"
    end

    # -----------------------------------------------------------------------
    # Accepts (prompts)
    # -----------------------------------------------------------------------

    test "accepts meta entries inside prompts > list_result block" do
      config =
        module("Meta") do
          prompts do
            list_result do
              meta "key", "value"
            end
          end
        end
        |> compile_config()

      assert config.prompts.list_result == %{_meta: %{"key" => "value"}, extras: nil}
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when meta is used inside tools block" do
      module("Meta") do
        tools do
          meta "key", "value"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'meta' here")
    end
  end
end
