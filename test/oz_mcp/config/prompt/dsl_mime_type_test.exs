#
# Tests for the `mime_type/1` macro of the prompt DSL (icon property).
# See: lib/oz_mcp/config/prompt/dsl.ex
#
defmodule OzMcp.Config.Prompt.DSLMimeTypeTest do
  use ExUnit.Case, async: true

  import Support.Factories.Prompt

  describe "mime_type/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a mime type string" do
      prompt =
        module("MimeType") do
          prompt("code_review") do
            title("T")

            icon do
              mime_type("image/png")
            end
          end
        end
        |> compile_one_prompt()

      [icon] = prompt.icons
      assert icon.mimeType == "image/png"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when mime_type is used multiple times" do
      module("MimeType") do
        prompt("code_review") do
          title("T")

          icon do
            mime_type("image/png")
            mime_type("image/jpeg")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'mime_type' multiple times")
    end

    test "raises when mime_type is not a string" do
      module("MimeType") do
        prompt("code_review") do
          title("T")
          icon(mime_type: 123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'mime_type' must be a string, got: 123")
    end

    test "raises when mime_type is an empty string" do
      module("MimeType") do
        prompt("code_review") do
          title("T")
          icon(mime_type: "")
        end
      end
      |> assert_compile_raise(ArgumentError, "'mime_type' cannot be an empty string")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when mime_type is used at root level (only prompt/2 is imported)" do
      module("MimeType") do
        mime_type("image/png")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Prompt.MimeType",
        "undefined function mime_type/1"
      )
    end

    test "raises when mime_type is used directly inside prompt block" do
      module("MimeType") do
        prompt("code_review") do
          title("T")
          mime_type("image/png")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'mime_type' here")
    end
  end
end
