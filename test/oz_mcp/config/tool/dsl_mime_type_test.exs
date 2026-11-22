#
# Tests for the `mime_type/1` macro of the tool DSL (icon property).
# See: lib/oz_mcp/config/tool/dsl.ex
#
# NOTE: In the tool DSL, `mime_type/1` is valid ONLY at `[:tool, :icon]`.
# Unlike the resource DSL, it is NOT valid at the tool level.
#
defmodule OzMcp.Config.Tool.DSLMimeTypeTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "mime_type/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a mime_type string inside icon" do
      tool =
        module("MimeType") do
          tool("get_date") do
            title("T")

            icon do
              mime_type("image/png")
            end
          end
        end
        |> compile_one_tool()

      [icon] = tool.icons
      assert icon.mimeType == "image/png"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when mime_type is used multiple times" do
      module("MimeType") do
        tool("get_date") do
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
        tool("get_date") do
          title("T")
          icon(mime_type: 123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'mime_type' must be a string, got: 123")
    end

    test "raises when mime_type is an empty string" do
      module("MimeType") do
        tool("get_date") do
          title("T")
          icon(mime_type: "")
        end
      end
      |> assert_compile_raise(ArgumentError, "'mime_type' cannot be an empty string")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when mime_type is used at root level (only tool/2 is imported)" do
      module("MimeType") do
        mime_type("text/plain")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.MimeType",
        "undefined function mime_type/1"
      )
    end

    test "raises when mime_type is used directly inside tool block" do
      #
      # NOTE: Unlike the resource DSL, mime_type is NOT valid at the tool level.
      #
      module("MimeType") do
        tool("get_date") do
          title("T")
          mime_type("text/plain")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'mime_type' here")
    end

    test "raises when mime_type is used inside annotations block" do
      module("MimeType") do
        tool("get_date") do
          title("T")

          annotations(read_only_hint: true) do
            mime_type("text/plain")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'mime_type' here")
    end

    test "raises when mime_type is used inside execution block" do
      module("MimeType") do
        tool("get_date") do
          title("T")

          execution do
            mime_type("text/plain")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'mime_type' here")
    end
  end
end
