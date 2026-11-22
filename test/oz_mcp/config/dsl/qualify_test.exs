#
# Tests for the qualify helper that the DSL modules call on the block
# of their macros.
# See: lib/oz_mcp/config/dsl/qualify.ex
#
defmodule OzMcp.Config.DSL.QualifyTest do
  use ExUnit.Case, async: true

  alias OzMcp.Config.DSL.Qualify
  alias Support.Helpers.Utils

  defmodule FakeDSL do
  end

  defmodule TitleHelper do
    def title(value), do: "helper:" <> value
  end

  @mod_string "OzMcp.Config.DSL.QualifyTest.FakeDSL"

  describe "statements/3" do
    # -----------------------------------------------------------------------
    # Statements of the block
    # -----------------------------------------------------------------------

    test "qualifies a listed statement of a block" do
      ast =
        quote do
          title("hello")
        end

      result = Qualify.statements(ast, FakeDSL, title: 1)

      assert Macro.to_string(result) == "#{@mod_string}.title(\"hello\")"
    end

    test "qualifies a single statement with no block" do
      ast = quote do: title("hello")

      assert {{:., _, [FakeDSL, :title]}, _, ["hello"]} =
               Qualify.statements(ast, FakeDSL, title: 1)
    end

    test "does not rewrite a call inside a value" do
      ast = quote do: description(title("x"))

      assert {{:., _, [FakeDSL, :description]}, _, [{:title, _, ["x"]}]} =
               Qualify.statements(ast, FakeDSL, description: 1, title: 1)
    end

    test "leaves a call that is already qualified untouched" do
      ast = quote do: FakeDSL.title("a")

      assert Qualify.statements(ast, FakeDSL, title: 1) == ast
    end

    # -----------------------------------------------------------------------
    # Nested blocks
    # -----------------------------------------------------------------------

    test "goes into the do block of a qualified macro" do
      ast = quote do: icon(do: src("a"))

      assert {{:., _, [FakeDSL, :icon]}, _, [[do: {{:., _, [FakeDSL, :src]}, _, ["a"]}]]} =
               Qualify.statements(ast, FakeDSL, icon: 1, src: 1)
    end

    test "goes into the do and else blocks of an if and keeps the condition" do
      ast =
        quote do
          if flag("f") do
            title("a")
          else
            title("b")
          end
        end

      string = Macro.to_string(Qualify.statements(ast, FakeDSL, title: 1, flag: 1))

      assert string =~ "#{@mod_string}.title(\"a\")"
      assert string =~ "#{@mod_string}.title(\"b\")"

      # The condition is a value: `flag` is listed, but not qualified.
      #
      refute string =~ "#{@mod_string}.flag"
      assert string =~ "flag(\"f\")"
    end

    test "goes into the clause bodies of a case" do
      ast =
        quote do
          case v do
            :a -> title("a")
            :b -> title("b")
          end
        end

      string = Macro.to_string(Qualify.statements(ast, FakeDSL, title: 1))

      assert string =~ "#{@mod_string}.title(\"a\")"
      assert string =~ "#{@mod_string}.title(\"b\")"
    end

    test "goes into the clause bodies of a cond" do
      ast =
        quote do
          cond do
            ok?() -> title("a")
            maybe?() -> title("c")
            true -> title("b")
          end
        end

      string = Macro.to_string(Qualify.statements(ast, FakeDSL, title: 1))

      assert string =~ "#{@mod_string}.title(\"a\")"
      assert string =~ "#{@mod_string}.title(\"b\")"
      assert string =~ "#{@mod_string}.title(\"c\")"
    end

    test "goes into the block of a for and keeps the generator" do
      ast =
        quote do
          for item <- items do
            title(item)
          end
        end

      string = Macro.to_string(Qualify.statements(ast, FakeDSL, title: 1))

      assert string =~ "#{@mod_string}.title(item)"
      assert string =~ "item <- items"
    end

    test "goes into an inline do after other for options and keeps these options" do
      ast = quote(do: for(x <- [1], uniq: title("x"), do: title(x)))

      string = Macro.to_string(Qualify.statements(ast, FakeDSL, title: 1))

      assert string =~ "#{@mod_string}.title(x)"
      assert string =~ "uniq: title(\"x\")"
      refute string =~ "#{@mod_string}.title(\"x\")"
    end

    test "goes into a nested block" do
      ast =
        quote do
          if true do
            title "a"

            (
              description "b"
              title "c"
            )
          end
        end

      string = Macro.to_string(Qualify.statements(ast, FakeDSL, title: 1, description: 1))

      assert string =~ "#{@mod_string}.title(\"a\")"
      assert string =~ "#{@mod_string}.description(\"b\")"
      assert string =~ "#{@mod_string}.title(\"c\")"
    end

    # -----------------------------------------------------------------------
    # Integration with the tool DSL
    # -----------------------------------------------------------------------

    test "a tool module can call an imported function named like a macro in a value" do
      defmodule ImportedTitle do
        use OzMcp.Config.Tool
        import OzMcp.Config.DSL.QualifyTest.TitleHelper, only: [title: 1]

        tool "imported_title" do
          description title("x")
          title "real title"
        end

        def call(_ctx, _params), do: :ok
      end

      [tool] = ImportedTitle.list()

      assert tool.description == "helper:x"
      assert tool.title == "real title"
    end

    test "a tool block keeps if, case, cond and for around the macros" do
      defmodule ControlFlow do
        use OzMcp.Config.Tool

        tool "control_flow" do
          title "T"
          description "D"

          if true do
            meta "if", "1"
          end

          case :a do
            :a -> meta "case", "1"
            _ -> nil
          end

          cond do
            1 == 1 -> meta "cond", "1"
            1 == 2 -> meta "never", "1"
            true -> nil
          end

          for _k <- ["for"] do
            meta "for", "1"
          end
        end

        def call(_ctx, _params), do: :ok
      end

      [tool] = ControlFlow.list()

      assert tool._meta == %{"if" => "1", "case" => "1", "cond" => "1", "for" => "1"}
    end

    test "a tool block keeps a for with an inline option" do
      defmodule ForInlineOption do
        use OzMcp.Config.Tool

        tool "for_inline_option" do
          title "T"
          description "D"

          for k <- ["a"], uniq: true, do: meta(k, "1")
        end

        def call(_ctx, _params), do: :ok
      end

      [tool] = ForInlineOption.list()

      assert tool._meta == %{"a" => "1"}
    end

    test "a DSL macro inside a fn is a compile error" do
      diagnostics =
        Utils.capture_diagnostics(fn ->
          assert_raise CompileError, ~r/cannot compile module/, fn ->
            defmodule FnMacro do
              use OzMcp.Config.Tool

              tool "fn_macro" do
                title "T"
                description "D"

                Enum.each(["a"], fn k -> meta k, 1 end)
              end
            end
          end
        end)

      assert diagnostics =~ "undefined function meta/2"
    end
  end
end
