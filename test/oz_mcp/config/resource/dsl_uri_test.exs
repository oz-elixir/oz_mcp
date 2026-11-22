#
# Tests for the `uri/1` macro of the resource DSL.
# See: lib/oz_mcp/config/resource/dsl.ex
#
defmodule OzMcp.Config.Resource.DSLUriTest do
  use ExUnit.Case, async: true

  import Support.Factories.Resource

  describe "uri/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts file:///logs/app.log" do
      resource =
        module("Uri") do
          resource("app.log", uri: "file:///logs/app.log")
        end
        |> compile_one_resource()

      assert resource.uri == "file:///logs/app.log"
    end

    test "accepts a custom scheme: myapp://notes/1" do
      resource =
        module("Uri") do
          resource("notes", uri: "myapp://notes/1")
        end
        |> compile_one_resource()

      assert resource.uri == "myapp://notes/1"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when uri is used multiple times" do
      module("Uri") do
        resource("doc.md", uri: :_none_) do
          uri("file:///doc.md")
          uri("file:///other.md")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'uri' multiple times")
    end

    test "raises when uri is not a string" do
      module("Uri") do
        resource("doc.md", uri: 123)
      end
      |> assert_compile_raise(ArgumentError, "'uri' must be a string, got: 123")
    end

    test "raises when uri is an empty string" do
      module("Uri") do
        resource("doc.md", uri: "")
      end
      |> assert_compile_raise(ArgumentError, "'uri' cannot be an empty string")
    end

    test "raises for 'notes/1' (no scheme)" do
      module("Uri") do
        resource("doc.md", uri: "notes/1")
      end
      |> assert_compile_raise(
        ArgumentError,
        ~s|'uri' must be an absolute URI with a scheme, got: "notes/1"|
      )
    end

    test "raises for 'http://a b' (a space)" do
      module("Uri") do
        resource("doc.md", uri: "http://a b")
      end
      |> assert_compile_raise(
        ArgumentError,
        ~s|'uri' must be an absolute URI with a scheme, got: "http://a b"|
      )
    end

    test "raises for '1abc://x' (the scheme starts with a digit)" do
      module("Uri") do
        resource("doc.md", uri: "1abc://x")
      end
      |> assert_compile_raise(
        ArgumentError,
        ~s|'uri' must be an absolute URI with a scheme, got: "1abc://x"|
      )
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when uri is used at root level (only resource/2 is imported)" do
      module("Uri") do
        uri("file:///doc.md")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Resource.Uri",
        "undefined function uri/1"
      )
    end

    test "raises when uri is used inside icon block" do
      module("Uri") do
        resource("doc.md") do
          icon do
            uri("file:///doc.md")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'uri' here")
    end

    test "raises when uri is used inside annotations block" do
      module("Uri") do
        resource("doc.md") do
          annotations(audience: ["user"]) do
            uri("file:///doc.md")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'uri' here")
    end
  end
end
