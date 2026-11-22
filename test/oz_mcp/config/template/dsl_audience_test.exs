#
# Tests for the `audience/1` macro of the template DSL.
# See: lib/oz_mcp/config/template/dsl.ex
#
defmodule OzMcp.Config.Template.DSLAudienceTest do
  use ExUnit.Case, async: true

  import Support.Factories.Template

  describe "audience/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts audience [\"user\"]" do
      template =
        module("Audience") do
          template("doc") do
            annotations(audience: ["user"])
          end
        end
        |> compile_one_template()

      assert template.annotations.audience == ["user"]
    end

    test "accepts audience [\"assistant\"]" do
      template =
        module("Audience") do
          template("doc") do
            annotations(audience: ["assistant"])
          end
        end
        |> compile_one_template()

      assert template.annotations.audience == ["assistant"]
    end

    test ~S(accepts audience ["user", "assistant"]) do
      template =
        module("Audience") do
          template("doc") do
            annotations(audience: ["user", "assistant"])
          end
        end
        |> compile_one_template()

      assert template.annotations.audience == ["user", "assistant"]
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when audience is used multiple times" do
      module("Audience") do
        template("doc") do
          annotations(audience: ["user"]) do
            audience(["user"])
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'audience' multiple times")
    end

    test "raises when audience is not a list (string)" do
      module("Audience") do
        template("doc") do
          annotations(audience: "user")
        end
      end
      |> assert_compile_raise(ArgumentError, "'audience' must be a list, got: \"user\"")
    end

    test "raises when audience is not a list (integer)" do
      module("Audience") do
        template("doc") do
          annotations(audience: 123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'audience' must be a list, got: 123")
    end

    test "raises when audience is an empty list" do
      module("Audience") do
        template("doc") do
          annotations(audience: [])
        end
      end
      |> assert_compile_raise(ArgumentError, "'audience' cannot be an empty list")
    end

    test "raises when audience list contains a non-string element" do
      module("Audience") do
        template("doc") do
          annotations(audience: [0])
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'audience' elements must be \"user\" or \"assistant\", got: [0]"
      )
    end

    test "raises when audience list contains an invalid string" do
      module("Audience") do
        template("doc") do
          annotations(audience: ["invalid"])
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'audience' elements must be \"user\" or \"assistant\", got: [\"invalid\"]"
      )
    end

    test "raises when audience list contains duplicates" do
      module("Audience") do
        template("doc") do
          annotations(audience: ["user", "user"])
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'audience' has duplicates elements, got: [\"user\", \"user\"]"
      )

      module("Audience") do
        template("doc") do
          annotations(audience: ["assistant", "user", "assistant"])
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'audience' has duplicates elements, got: [\"assistant\", \"user\", \"assistant\"]"
      )
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when audience is used at root level (only template/2 is imported)" do
      module("Audience") do
        audience(["user"])
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Template.Audience",
        "undefined function audience/1"
      )
    end

    test "raises when audience is used directly inside template block" do
      module("Audience") do
        template("doc") do
          audience(["user"])
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'audience' here")
    end

    test "raises when audience is used inside icon block" do
      module("Audience") do
        template("doc") do
          icon do
            audience(["user"])
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'audience' here")
    end
  end
end
