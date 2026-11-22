#
# Tests for the `mime_type/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLMimeTypeTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "mime_type/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a non-empty string" do
      config =
        module("MimeType") do
          server_info do
            icon(mime_type: "image/png")
          end
        end
        |> compile_config()

      assert hd(config.server_info.icons).mimeType == "image/png"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when mime_type is not a string" do
      module("MimeType") do
        server_info do
          icon(mime_type: 123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'mime_type' must be a string, got: 123")
    end

    test "raises when mime_type is an empty string" do
      module("MimeType") do
        server_info do
          icon(mime_type: "")
        end
      end
      |> assert_compile_raise(ArgumentError, "'mime_type' cannot be an empty string")
    end

    test "raises when mime_type is used multiple times" do
      module("MimeType") do
        server_info do
          icon do
            mime_type "image/png"
            mime_type "image/jpeg"
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'mime_type' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises mime_type cannot be at root level" do
      module("MimeType") do
        mime_type "image/png"
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.MimeType",
        "undefined function mime_type/1"
      )
    end

    test "raises when mime_type is used directly inside server_info block" do
      module("MimeType") do
        server_info do
          mime_type "image/png"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'mime_type' here")
    end

    test "raises when mime_type is used inside tools block" do
      module("MimeType") do
        tools do
          mime_type "image/png"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'mime_type' here")
    end
  end
end
