#
# Tests for the `mime_type/1` macro of the resource DSL.
# See: lib/oz_mcp/config/resource/dsl.ex
#
defmodule OzMcp.Config.Resource.DSLMimeTypeTest do
  use ExUnit.Case, async: true

  import Support.Factories.Resource

  describe "mime_type/1" do
    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when mime_type is used multiple times" do
      module("MimeType") do
        resource("doc.md") do
          mime_type("text/plain")
          mime_type("text/markdown")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'mime_type' multiple times")
    end

    test "raises when mime_type is not a string" do
      module("MimeType") do
        resource("doc.md", mime_type: 123)
      end
      |> assert_compile_raise(ArgumentError, "'mime_type' must be a string, got: 123")
    end

    test "raises when mime_type is an empty string" do
      module("MimeType") do
        resource("doc.md", mime_type: "")
      end
      |> assert_compile_raise(ArgumentError, "'mime_type' cannot be an empty string")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when mime_type is used at root level (only resource/2 is imported)" do
      module("MimeType") do
        mime_type("text/plain")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Resource.MimeType",
        "undefined function mime_type/1"
      )
    end

    test "raises when mime_type is used inside annotations block" do
      module("MimeType") do
        resource("doc.md") do
          annotations(audience: ["user"]) do
            mime_type("text/plain")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'mime_type' here")
    end
  end
end
