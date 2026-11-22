#
# Tests for the `src/1` macro of the tool DSL (icon property).
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLSrcTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "src/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a src string" do
      tool =
        module("Src") do
          tool("get_date", title: "T") do
            icon(src: "https://a.com/icon.png")
          end
        end
        |> compile_one_tool()

      [icon] = tool.icons
      assert icon.src == "https://a.com/icon.png"
    end

    test "accepts a data: URI" do
      tool =
        module("Src") do
          tool("get_date", title: "T") do
            icon(src: "data:image/png;base64,AAAA")
          end
        end
        |> compile_one_tool()

      [icon] = tool.icons
      assert icon.src == "data:image/png;base64,AAAA"
    end

    test "accepts http: for localhost" do
      tool =
        module("Src") do
          tool("get_date", title: "T") do
            icon(src: "http://localhost:4000/a.png")
          end
        end
        |> compile_one_tool()

      [icon] = tool.icons
      assert icon.src == "http://localhost:4000/a.png"
    end

    test "accepts http: for ::1" do
      tool =
        module("Src") do
          tool("get_date", title: "T") do
            icon(src: "http://[::1]:4000/a.png")
          end
        end
        |> compile_one_tool()

      [icon] = tool.icons
      assert icon.src == "http://[::1]:4000/a.png"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises for http: with a public host" do
      module("Src") do
        tool("get_date") do
          title("T")
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
        tool("get_date") do
          title("T")
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
        tool("get_date") do
          title("T")
          icon(src: "/icons/a.png")
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~s|'src' must be an https: URL, an http: URL of a loopback host, or a data: URI, got: "/icons/a.png"|
      )
    end

    test "raises when src is used multiple times" do
      module("Src") do
        tool("get_date") do
          title("T")

          icon do
            src("https://a.com/icon.png")
            src("https://b.com/icon.png")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'src' multiple times")
    end

    test "raises when src is not a string" do
      module("Src") do
        tool("get_date") do
          title("T")
          icon(src: 123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'src' must be a string, got: 123")
    end

    test "raises when src is an empty string" do
      module("Src") do
        tool("get_date") do
          title("T")
          icon(src: "")
        end
      end
      |> assert_compile_raise(ArgumentError, "'src' cannot be an empty string")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when src is used at root level (only tool/2 is imported)" do
      module("Src") do
        src("https://a.com/icon.png")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.Src",
        "undefined function src/1"
      )
    end

    test "raises when src is used directly inside tool block" do
      module("Src") do
        tool("get_date") do
          title("T")
          src("https://a.com/icon.png")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'src' here")
    end

    test "raises when src is used inside annotations block" do
      module("Src") do
        tool("get_date") do
          title("T")

          annotations(read_only_hint: true) do
            src("https://a.com/icon.png")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'src' here")
    end

    test "raises when src is used inside execution block" do
      module("Src") do
        tool("get_date") do
          title("T")

          execution do
            src("https://a.com/icon.png")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'src' here")
    end
  end
end
