#
# Tests for the `meta/2` macro of the template DSL.
# See: lib/oz_mcp/config/template/dsl.ex
#
defmodule OzMcp.Config.Template.DSLMetaTest do
  use ExUnit.Case, async: true

  import Support.Factories.Template

  describe "meta/2" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a string key and string value" do
      template =
        module("Meta") do
          template("doc") do
            meta("key", "value")
          end
        end
        |> compile_one_template()

      assert template._meta == %{"key" => "value"}
    end

    test "accepts multiple meta entries" do
      template =
        module("Meta") do
          template("doc") do
            meta("key1", "value1")
            meta("key2", "value2")
          end
        end
        |> compile_one_template()

      assert template._meta == %{"key1" => "value1", "key2" => "value2"}
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when meta key is not a string" do
      module("Meta") do
        template("doc") do
          meta(123, "value")
        end
      end
      |> assert_compile_raise(ArgumentError, "'key' must be a string, got: 123")
    end

    test "raises when meta key already exists" do
      module("Meta") do
        template("doc") do
          meta("key", "first")
          meta("key", "second")
        end
      end
      |> assert_compile_raise(RuntimeError, "key 'key' already exists")
    end

    # -----------------------------------------------------------------------
    # Special
    # -----------------------------------------------------------------------

    test "meta converts atom value to string" do
      template =
        module("Meta") do
          template("doc") do
            meta("my_key", :my_value)
          end
        end
        |> compile_one_template()

      assert template._meta == %{"my_key" => "my_value"}
    end

    test "meta keeps true as boolean" do
      template =
        module("Meta") do
          template("doc") do
            meta("beta", true)
          end
        end
        |> compile_one_template()

      assert template._meta == %{"beta" => true}
    end

    test "meta keeps false as boolean" do
      template =
        module("Meta") do
          template("doc") do
            meta("beta", false)
          end
        end
        |> compile_one_template()

      assert template._meta == %{"beta" => false}
    end

    test "meta keeps nil as null" do
      template =
        module("Meta") do
          template("doc") do
            meta("beta", nil)
          end
        end
        |> compile_one_template()

      assert template._meta == %{"beta" => nil}
    end

    test "raises when meta key is nil" do
      module("Meta") do
        template("doc") do
          meta(nil, "value")
        end
      end
      |> assert_compile_raise(ArgumentError, "'key' must be a string, got: nil")
    end

    test "meta converts atom key to string" do
      template =
        module("Meta") do
          template("doc") do
            meta(:my_key, "my_value")
          end
        end
        |> compile_one_template()

      assert template._meta == %{"my_key" => "my_value"}
    end

    test "meta rejects non-string non-atom key with ArgumentError" do
      module("Meta") do
        template("doc") do
          meta(123, "my_value")
        end
      end
      |> assert_compile_raise(ArgumentError, "'key' must be a string, got: 123")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when meta is used at root level (only template/2 is imported)" do
      module("Meta") do
        meta("key", "value")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Template.Meta",
        "undefined function meta/2"
      )
    end

    test "raises when meta is used inside annotations block" do
      module("Meta") do
        template("doc") do
          annotations(audience: ["user"]) do
            meta("key", "value")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'meta' here")
    end

    test "raises when meta is used inside icon block" do
      module("Meta") do
        template("doc") do
          icon do
            meta("key", "value")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'meta' here")
    end
  end
end
