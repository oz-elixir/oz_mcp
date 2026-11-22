#
# Tests for the `meta/2` macro of the tool DSL.
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLMetaTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "meta/2" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a string key and string value" do
      tool =
        module("Meta") do
          tool("get_date") do
            title("T")
            meta("key", "value")
          end
        end
        |> compile_one_tool()

      assert tool._meta == %{"key" => "value"}
    end

    test "accepts multiple meta entries" do
      tool =
        module("Meta") do
          tool("get_date") do
            title("T")
            meta("key1", "value1")
            meta("key2", "value2")
          end
        end
        |> compile_one_tool()

      assert tool._meta == %{"key1" => "value1", "key2" => "value2"}
    end

    # -----------------------------------------------------------------------
    # Special
    # -----------------------------------------------------------------------

    test "meta converts atom key to string" do
      tool =
        module("Meta") do
          tool("get_date") do
            title("T")
            meta(:my_key, "my_value")
          end
        end
        |> compile_one_tool()

      assert tool._meta == %{"my_key" => "my_value"}
    end

    test "meta converts atom value to string" do
      tool =
        module("Meta") do
          tool("get_date") do
            title("T")
            meta("my_key", :my_value)
          end
        end
        |> compile_one_tool()

      assert tool._meta == %{"my_key" => "my_value"}
    end

    test "meta keeps true as boolean" do
      tool =
        module("Meta") do
          tool("get_date") do
            title("T")
            meta("beta", true)
          end
        end
        |> compile_one_tool()

      assert tool._meta == %{"beta" => true}
    end

    test "meta keeps false as boolean" do
      tool =
        module("Meta") do
          tool("get_date") do
            title("T")
            meta("beta", false)
          end
        end
        |> compile_one_tool()

      assert tool._meta == %{"beta" => false}
    end

    test "meta keeps nil as null" do
      tool =
        module("Meta") do
          tool("get_date") do
            title("T")
            meta("beta", nil)
          end
        end
        |> compile_one_tool()

      assert tool._meta == %{"beta" => nil}
    end

    test "raises when meta key is nil" do
      module("Meta") do
        tool("get_date") do
          title("T")
          meta(nil, "value")
        end
      end
      |> assert_compile_raise(ArgumentError, "'key' must be a string, got: nil")
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when meta key is not a string" do
      module("Meta") do
        tool("get_date") do
          title("T")
          meta(123, "value")
        end
      end
      |> assert_compile_raise(ArgumentError, "'key' must be a string, got: 123")
    end

    test "raises when meta key already exists" do
      module("Meta") do
        tool("get_date") do
          title("T")
          meta("key", "first")
          meta("key", "second")
        end
      end
      |> assert_compile_raise(RuntimeError, "key 'key' already exists")
    end

    test "raises when meta key is not a valid _meta name" do
      module("Meta") do
        tool("get_date") do
          title("T")
          meta("a b", "value")
        end
      end
      |> assert_compile_raise(ArgumentError, "bad _meta key \"a b\": bad name")
    end

    test "raises when meta key has a reserved prefix" do
      module("Meta") do
        tool("get_date") do
          title("T")
          meta("dev.mcp/x", "value")
        end
      end
      |> assert_compile_raise(ArgumentError, "the _meta prefix of \"dev.mcp/x\" is reserved")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when meta is used at root level (only tool/2 is imported)" do
      module("Meta") do
        meta("key", "value")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.Meta",
        "undefined function meta/2"
      )
    end

    test "raises when meta is used inside icon block" do
      module("Meta") do
        tool("get_date") do
          title("T")

          icon do
            meta("key", "value")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'meta' here")
    end

    test "raises when meta is used inside annotations block" do
      module("Meta") do
        tool("get_date") do
          title("T")

          annotations(read_only_hint: true) do
            meta("key", "value")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'meta' here")
    end

    test "raises when meta is used inside execution block" do
      module("Meta") do
        tool("get_date") do
          title("T")

          execution do
            meta("key", "value")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'meta' here")
    end
  end
end
