defmodule OzMcp.Config.TemplateTest do
  use ExUnit.Case, async: true
  import Support.Factories.Template

  # -----------------------------------------------------------------------
  # __using__/1
  # -----------------------------------------------------------------------

  describe "__using__/1 macro" do
    # -----------------------------------------------------------------------
    # dsl? option
    # -----------------------------------------------------------------------

    test "dsl? option defaults to true (DSL active by default)" do
      mod =
        module("DslDefault") do
          template("doc", title: "Doc", description: "A doc")
        end
        |> compile()

      # The DSL auto-generates list/0.
      #
      assert function_exported?(mod, :list, 0)
    end

    test "dsl?: true explicitly activates the DSL" do
      mod =
        module("DslTrue", _dsl_: true) do
          template("doc", title: "Doc", description: "A doc")
        end
        |> compile()

      assert function_exported?(mod, :list, 0)
    end

    test "dsl?: false deactivates the DSL (manual callbacks required)" do
      code =
        quote do
          def list, do: [:a, :b]
        end

      mod =
        module("DslFalse", _dsl_: false, _code_: code)
        |> compile()

      # With the DSL off, the module defines list/0.
      #
      assert mod.list() == [:a, :b]
    end

    test "raises when dsl? option is not a boolean" do
      module("DslNotBoolean", _dsl_: "yes")
      |> assert_compile_raise(ArgumentError, "dsl? option must be a boolean")
    end

    # -----------------------------------------------------------------------
    # warn? option
    # -----------------------------------------------------------------------

    test "raises when warn? option is not a boolean" do
      module("WarnNotBoolean", _warn_: "yes")
      |> assert_compile_raise(ArgumentError, "warn? option must be a boolean")
    end

    test "warn? option set to true is accepted" do
      module("WarnTrue", _warn_: true) do
        template("doc", title: "Doc", description: "A doc")
      end
      |> compile()
    end

    test "warn? option set to false is accepted" do
      module("WarnFalse") do
        template("doc", title: "Doc", description: "A doc")
      end
      |> compile()
    end

    test "warn? option defaults to true" do
      module("DefaultWarnIsTrue", _warn_: :_none_) do
        template("doc", description: "A doc")
      end
      |> assert_compile_warning("The template doc does not have a title configuration")
    end
  end

  # -----------------------------------------------------------------------
  # __before_compile__/1 required callbacks
  # -----------------------------------------------------------------------

  describe "__before_compile__/1 required callbacks" do
    #
    # only list/0 is required.
    #
    test "raises when list/0 is not defined" do
      code =
        quote do
        end

      module("NoList", _dsl_: false, _code_: code)
      |> assert_compile_raise(RuntimeError, "you must satisfy the list/0 behaviour")
    end

    test "compiles when only list/0 is defined " do
      code =
        quote do
          def list, do: [:a, :b]
        end

      mod =
        module("OnlyList", _dsl_: false, _code_: code)
        |> compile()

      assert function_exported?(mod, :list, 0)
    end

    # ----- DSL modules conform to the behaviour

    test "DSL modules implement list/0" do
      Code.ensure_loaded(Support.Entities.Templates.DslTest.Basic)
      assert function_exported?(Support.Entities.Templates.DslTest.Basic, :list, 0)
    end
  end

  # -----------------------------------------------------------------------
  # list/0
  # -----------------------------------------------------------------------

  describe "list/0 (DSL modules)" do
    test "list/0 returns all declared templates in order" do
      mod =
        module("PaginateDslFull") do
          template("first", title: "T", description: "D")
          template("second", title: "T", description: "D")
          template("third", title: "T", description: "D")
        end
        |> compile()

      names = fn templates -> Enum.map(templates, & &1.name) end

      assert names.(mod.list()) == ["first", "second", "third"]
    end
  end
end
