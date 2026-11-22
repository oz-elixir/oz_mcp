#
# Tests for the `uri_template/1` macro of the template DSL.
# See: lib/oz_mcp/config/template/dsl.ex
#
defmodule OzMcp.Config.Template.DSLUriTemplateTest do
  use ExUnit.Case, async: true

  import Support.Factories.Template

  describe "uri_template/1" do
    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when uri_template is used multiple times" do
      module("UriTemplate") do
        template("doc", uri_template: :_none_) do
          uri_template("file://docs/a/{path}")
          uri_template("file://docs/b/{path}")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'uri_template' multiple times")
    end

    test "raises when uri_template is not a string" do
      module("UriTemplate") do
        template("doc", uri_template: 123)
      end
      |> assert_compile_raise(ArgumentError, "'uri_template' must be a string, got: 123")
    end

    test "raises when uri_template is an empty string" do
      module("UriTemplate") do
        template("doc", uri_template: "")
      end
      |> assert_compile_raise(ArgumentError, "'uri_template' cannot be an empty string")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when uri_template is used at root level (only template/2 is imported)" do
      module("UriTemplate") do
        uri_template("file://docs/{path}")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Template.UriTemplate",
        "undefined function uri_template/1"
      )
    end

    test "raises when uri_template is used inside icon block" do
      module("UriTemplate") do
        template("doc") do
          icon do
            uri_template("file://docs/{path}")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'uri_template' here")
    end

    test "raises when uri_template is used inside annotations block" do
      module("UriTemplate") do
        template("doc") do
          annotations(audience: ["user"]) do
            uri_template("file://docs/{path}")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'uri_template' here")
    end

    # -----------------------------------------------------------------------
    # URI template syntax (compile-time check)
    # -----------------------------------------------------------------------

    test "raises when the template has an unclosed expression" do
      module("UriTemplate") do
        template("doc", uri_template: "file:///{a")
      end
      |> assert_compile_raise(
        ArgumentError,
        ~r/template "doc": invalid URI template "file:\/\/\/\{a": empty or unclosed expression at position 8/
      )
    end

    test "raises when the template has an empty expression" do
      module("UriTemplate") do
        template("doc", uri_template: "file:///{}/")
      end
      |> assert_compile_raise(
        ArgumentError,
        ~r/template "doc": invalid URI template "file:\/\/\/\{\}\/": empty or unclosed expression at position 8/
      )
    end

    test "raises when the template has two adjacent expressions without a prefix operator" do
      module("UriTemplate") do
        template("doc", uri_template: "a/{b}{c}")
      end
      |> assert_compile_raise(
        ArgumentError,
        ~r/template "doc": invalid URI template "a\/\{b\}\{c\}": ambiguous adjacent expressions at position 5/
      )
    end

    test "raises when the template declares a variable two times" do
      module("UriTemplate") do
        template("doc", uri_template: "{a}/{a}")
      end
      |> assert_compile_raise(
        ArgumentError,
        ~r/template "doc": invalid URI template "\{a\}\/\{a\}": duplicate variable name "a" at position 4/
      )
    end

    test "raises when the template uses a level 4 modifier" do
      module("UriTemplate") do
        template("doc", uri_template: "file:///{a*}")
      end
      |> assert_compile_raise(
        ArgumentError,
        ~r/template "doc": invalid URI template "file:\/\/\/\{a\*\}": level 4 modifiers are not supported/
      )
    end

    test "raises when the template uses a reserved operator" do
      module("UriTemplate") do
        template("doc", uri_template: "file:///{=a}")
      end
      |> assert_compile_raise(
        ArgumentError,
        ~r/template "doc": invalid URI template "file:\/\/\/\{=a\}": reserved operator '=' at position 8/
      )
    end

    test "raises when an expression follows a query expression" do
      module("UriTemplate") do
        template("doc", uri_template: "s{?a}{&b}")
      end
      |> assert_compile_raise(
        ArgumentError,
        ~r/template "doc": invalid URI template "s\{\?a\}\{&b\}": only \{#\.\.\.\} may follow \{\?\.\.\.\} or \{&\.\.\.\} at position 5/
      )
    end
  end
end
