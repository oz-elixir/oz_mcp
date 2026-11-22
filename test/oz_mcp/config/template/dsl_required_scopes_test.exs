#
# Tests for the `required_scopes/1` macro of the template DSL.
# See: lib/oz_mcp/config/template/dsl.ex
#
defmodule OzMcp.Config.Template.DSLRequiredScopesTest do
  use ExUnit.Case, async: true

  import Support.Factories.Template

  describe "required_scopes/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "required_scopes is stored in the struct" do
      module =
        module("Scoped") do
          template("docs") do
            title("Docs")
            description("Documentation files")
            required_scopes(["files:write", "files:delete"])
          end

          template("public") do
            title("Public")
            description("Public files")
          end
        end
        |> compile()

      assert [%{required_scopes: ["files:write", "files:delete"]}, %{required_scopes: []}] =
               module.list()

      refute function_exported?(module, :__required_scopes__, 0)
    end

    test "a repeated scope is stored once" do
      module =
        module("Repeated") do
          template("docs") do
            title("Docs")
            description("Documentation files")
            required_scopes(["a", "a", "b"])
          end
        end
        |> compile()

      assert [%{required_scopes: ["a", "b"]}] = module.list()
    end

    test "a module with no scope has empty required_scopes" do
      module =
        module("NoScope") do
          template("docs") do
            title("Docs")
            description("Documentation files")
          end
        end
        |> compile()

      assert [%{required_scopes: []}] = module.list()
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when the list is empty" do
      module("Empty") do
        template("docs") do
          title("Docs")
          description("Documentation files")
          required_scopes([])
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'required_scopes' cannot be an empty list, remove it"
      )
    end

    test "raises when the value is not a list" do
      module("NotList") do
        template("docs") do
          title("Docs")
          description("Documentation files")
          required_scopes("files:write")
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'required_scopes' must be a list of strings, got: \"files:write\""
      )
    end

    test "raises when a scope contains a space" do
      module("Space") do
        template("docs") do
          title("Docs")
          description("Documentation files")
          required_scopes(["a b"])
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~r"'required_scopes' entries must match the RFC 6749 scope-token syntax"
      )
    end

    test "raises when required_scopes is used multiple times" do
      module("Multiple") do
        template("docs") do
          title("Docs")
          description("Documentation files")
          required_scopes(["a"])
          required_scopes(["b"])
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'required_scopes' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when required_scopes is used at root level (only template/2 is imported)" do
      module("Root") do
        required_scopes(["a"])
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Template.Root",
        "undefined function required_scopes/1"
      )
    end

    test "raises when required_scopes is used inside icon block" do
      module("Icon") do
        template("docs") do
          title("Docs")
          description("Documentation files")

          icon do
            required_scopes(["a"])
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'required_scopes' here")
    end

    test "raises when required_scopes is used inside annotations block" do
      module("Annotations") do
        template("docs") do
          title("Docs")
          description("Documentation files")

          annotations(audience: ["user"]) do
            required_scopes(["a"])
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'required_scopes' here")
    end
  end
end
