#
# Tests for the qualify helper that the template DSL calls on the block
# of its macros.
# See: lib/oz_mcp/config/dsl/qualify.ex
#
defmodule OzMcp.Config.Template.DSLQualifyTest do
  use ExUnit.Case, async: true

  alias OzMcp.Config.DSL.Qualify
  alias OzMcp.Config.Template.DSL, as: TemplateDSL

  @module_string "OzMcp.Config.Template.DSL"

  describe "statements/3" do
    # -----------------------------------------------------------------------
    # Qualification
    # -----------------------------------------------------------------------

    test "qualifies a listed name/arity to the given module" do
      ast =
        quote do
          title("hello")
        end

      result = Qualify.statements(ast, TemplateDSL, title: 1)

      assert Macro.to_string(result) == "#{@module_string}.title(\"hello\")"
    end

    test "qualifies multiple listed names" do
      ast =
        quote do
          title("a")
          description("b")
        end

      result = Qualify.statements(ast, TemplateDSL, title: 1, description: 1)
      string = Macro.to_string(result)

      assert string =~ "#{@module_string}.title(\"a\")"
      assert string =~ "#{@module_string}.description(\"b\")"
    end

    test "leaves a name untouched when its arity is not listed" do
      ast =
        quote do
          title("a", "b")
        end

      # Only title/1 is listed, so title/2 is left as a bare call.
      #
      result = Qualify.statements(ast, TemplateDSL, title: 1)
      string = Macro.to_string(result)

      refute string =~ @module_string
      assert string =~ "title(\"a\", \"b\")"
    end

    test "leaves a name untouched when it is not listed at all" do
      ast =
        quote do
          unknown_macro("a")
        end

      result = Qualify.statements(ast, TemplateDSL, title: 1)
      string = Macro.to_string(result)

      refute string =~ @module_string
      assert string =~ "unknown_macro(\"a\")"
    end

    # -----------------------------------------------------------------------
    # Integration with the real template-DSL names
    # -----------------------------------------------------------------------

    test "qualifies the full set of template-DSL inner macros" do
      ast =
        quote do
          title("a")
          description("b")
          uri_template("file://docs/{path}")

          annotations do
            audience(["user"])
            priority(1)
            last_modified("2025-01-01T00:00:00Z")
          end

          icon do
            src("https://x")
          end

          mime_type("image/png")
          sizes(["16x16"])
          theme("light")
          meta("k", "v")
        end

      names = [
        title: 1,
        description: 1,
        mime_type: 1,
        meta: 2,
        annotations: 1,
        icon: 1,
        audience: 1,
        priority: 1,
        last_modified: 1,
        src: 1,
        sizes: 1,
        theme: 1,
        uri_template: 1
      ]

      result = Qualify.statements(ast, TemplateDSL, names)
      string = Macro.to_string(result)

      # Every listed call is now fully-qualified to the module.
      #
      assert string =~ "#{@module_string}.title"
      assert string =~ "#{@module_string}.description"
      assert string =~ "#{@module_string}.uri_template"
      assert string =~ "#{@module_string}.annotations"
      assert string =~ "#{@module_string}.audience"
      assert string =~ "#{@module_string}.priority"
      assert string =~ "#{@module_string}.last_modified"
      assert string =~ "#{@module_string}.icon"
      assert string =~ "#{@module_string}.src"
      assert string =~ "#{@module_string}.mime_type"
      assert string =~ "#{@module_string}.sizes"
      assert string =~ "#{@module_string}.theme"
      assert string =~ "#{@module_string}.meta"
    end
  end
end
