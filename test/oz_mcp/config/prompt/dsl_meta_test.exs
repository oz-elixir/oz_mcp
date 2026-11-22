#
# Tests for the `meta/2` macro of the prompt DSL.
# See: lib/oz_mcp/config/prompt/dsl.ex
#
defmodule OzMcp.Config.Prompt.DSLMetaTest do
  use ExUnit.Case, async: true

  import Support.Factories.Prompt

  describe "meta/2" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a string key and string value" do
      prompt =
        module("Meta") do
          prompt("code_review") do
            title("T")
            meta("key", "value")
          end
        end
        |> compile_one_prompt()

      assert prompt._meta == %{"key" => "value"}
    end

    test "accepts multiple meta entries" do
      prompt =
        module("Meta") do
          prompt("code_review") do
            title("T")
            meta("key1", "value1")
            meta("key2", "value2")
          end
        end
        |> compile_one_prompt()

      assert prompt._meta == %{"key1" => "value1", "key2" => "value2"}
    end

    # -----------------------------------------------------------------------
    # Special
    # -----------------------------------------------------------------------

    test "meta converts atom key to string" do
      prompt =
        module("Meta") do
          prompt("code_review") do
            title("T")
            meta(:my_key, "my_value")
          end
        end
        |> compile_one_prompt()

      assert prompt._meta == %{"my_key" => "my_value"}
    end

    test "meta converts atom value to string" do
      prompt =
        module("Meta") do
          prompt("code_review") do
            title("T")
            meta("my_key", :my_value)
          end
        end
        |> compile_one_prompt()

      assert prompt._meta == %{"my_key" => "my_value"}
    end

    test "meta keeps true as boolean" do
      prompt =
        module("Meta") do
          prompt("code_review") do
            title("T")
            meta("beta", true)
          end
        end
        |> compile_one_prompt()

      assert prompt._meta == %{"beta" => true}
    end

    test "meta keeps false as boolean" do
      prompt =
        module("Meta") do
          prompt("code_review") do
            title("T")
            meta("beta", false)
          end
        end
        |> compile_one_prompt()

      assert prompt._meta == %{"beta" => false}
    end

    test "meta keeps nil as null" do
      prompt =
        module("Meta") do
          prompt("code_review") do
            title("T")
            meta("beta", nil)
          end
        end
        |> compile_one_prompt()

      assert prompt._meta == %{"beta" => nil}
    end

    test "raises when meta key is nil" do
      module("Meta") do
        prompt("code_review") do
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
        prompt("code_review") do
          title("T")
          meta(123, "value")
        end
      end
      |> assert_compile_raise(ArgumentError, "'key' must be a string, got: 123")
    end

    test "raises when meta key already exists" do
      module("Meta") do
        prompt("code_review") do
          title("T")
          meta("key", "first")
          meta("key", "second")
        end
      end
      |> assert_compile_raise(RuntimeError, "key 'key' already exists")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when meta is used at root level (only prompt/2 is imported)" do
      module("Meta") do
        meta("key", "value")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Prompt.Meta",
        "undefined function meta/2"
      )
    end

    test "raises when meta is used inside icon block" do
      module("Meta") do
        prompt("code_review") do
          title("T")

          icon do
            meta("key", "value")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'meta' here")
    end
  end
end
