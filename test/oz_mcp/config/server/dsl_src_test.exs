#
# Tests for the `src/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLSrcTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "src/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a non-empty string" do
      config =
        module("Src") do
          server_info do
            icon(src: "https://a.com/icon.png")
          end
        end
        |> compile_config()

      assert hd(config.server_info.icons).src == "https://a.com/icon.png"
    end

    test "accepts a data: URI" do
      config =
        module("Src") do
          server_info do
            icon(src: "data:image/png;base64,AAAA")
          end
        end
        |> compile_config()

      assert hd(config.server_info.icons).src == "data:image/png;base64,AAAA"
    end

    test "accepts http: for localhost" do
      config =
        module("Src") do
          server_info do
            icon(src: "http://localhost:4000/a.png")
          end
        end
        |> compile_config()

      assert hd(config.server_info.icons).src == "http://localhost:4000/a.png"
    end

    test "accepts http: for ::1" do
      config =
        module("Src") do
          server_info do
            icon(src: "http://[::1]:4000/a.png")
          end
        end
        |> compile_config()

      assert hd(config.server_info.icons).src == "http://[::1]:4000/a.png"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises for http: with a public host" do
      module("Src") do
        server_info do
          icon(src: "http://example.com/a.png")
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~s|'src' must be an https: URL, an http: URL of a loopback host, or a data: URI, got: "http://example.com/a.png"|
      )
    end

    test "raises for javascript:" do
      module("Src") do
        server_info do
          icon(src: "javascript:alert(1)")
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~s|'src' must be an https: URL, an http: URL of a loopback host, or a data: URI, got: "javascript:alert(1)"|
      )
    end

    test "raises for a relative path" do
      module("Src") do
        server_info do
          icon(src: "/icons/a.png")
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~s|'src' must be an https: URL, an http: URL of a loopback host, or a data: URI, got: "/icons/a.png"|
      )
    end

    test "raises when src is not a string" do
      module("Src") do
        server_info do
          icon(src: 123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'src' must be a string, got: 123")
    end

    test "raises when src is an empty string" do
      module("Src") do
        server_info do
          icon(src: "")
        end
      end
      |> assert_compile_raise(ArgumentError, "'src' cannot be an empty string")
    end

    test "raises when src is used multiple times" do
      module("Src") do
        server_info do
          icon do
            src "https://a.com/icon.png"
            src "https://b.com/icon.png"
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'src' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises src cannot be at root level" do
      module("Src") do
        src "https://a.com/icon.png"
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Src",
        "undefined function src/1"
      )
    end

    test "raises when src is used directly inside server_info block" do
      module("Src") do
        server_info do
          src "https://a.com/icon.png"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'src' here")
    end

    test "raises when src is used inside tools block" do
      module("Src") do
        tools do
          src "https://a.com/icon.png"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'src' here")
    end
  end
end
