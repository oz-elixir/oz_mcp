defmodule OzMcp.Config.PromptTest do
  use ExUnit.Case, async: true
  import Support.Factories.Prompt

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
          prompt("code_review", title: "T", description: "D")
        end
        |> compile()

      # The DSL auto-generates list/0.
      #
      assert function_exported?(mod, :list, 0)
    end

    test "dsl?: true explicitly activates the DSL" do
      mod =
        module("DslTrue", _dsl_: true) do
          prompt("code_review", title: "T", description: "D")
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

      # With the DSL off, the module defines list/0 and get/2.
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
        prompt("code_review", title: "T", description: "D")
      end
      |> compile()
    end

    test "warn? option set to false is accepted" do
      module("WarnFalse") do
        prompt("code_review", title: "T", description: "D")
      end
      |> compile()
    end

    test "warn? option defaults to true" do
      module("DefaultWarnIsTrue", _warn_: :_none_) do
        prompt("code_review", description: "D")
      end
      |> assert_compile_warning("The prompt code_review does not have a title configuration")
    end
  end

  # -----------------------------------------------------------------------
  # __before_compile__/1 required callbacks
  # -----------------------------------------------------------------------

  describe "__before_compile__/1 required callbacks" do
    #
    # only list/0 and get/2 are required.
    #
    test "raises when list/0 is not defined" do
      module("NoList", _dsl_: false)
      |> assert_compile_raise(RuntimeError, "you must satisfy the list/0 behaviour")
    end

    test "raises when get/2 is not defined" do
      code =
        quote do
          def list, do: []
        end

      module("NoGet", _dsl_: false, _get_: :_none_, _code_: code)
      |> assert_compile_raise(
        RuntimeError,
        "you must satisfy the get/2 behaviour"
      )
    end

    test "raises when get/1 is defined instead of get/2" do
      code =
        quote do
          def list, do: []
          def get(_params), do: {:error, :wrong_arity}
        end

      module("GetArity1", _dsl_: false, _code_: code)
      |> assert_compile_raise(
        RuntimeError,
        "you must satisfy the get/2 behaviour"
      )
    end

    test "compiles when only list/0 and get/2 are defined " do
      code =
        quote do
          def list, do: [:a, :b]
          def get(_ctx, _params), do: {:error, :no_prompt}
        end

      mod =
        module("OnlyListAndGet", _dsl_: false, _code_: code)
        |> compile()

      assert function_exported?(mod, :list, 0)
      assert function_exported?(mod, :get, 2)
    end

    # ----- DSL modules conform to the behaviour

    test "DSL modules implement all required callbacks" do
      Code.ensure_loaded(Support.Entities.Prompts.DslTest.Basic)
      assert function_exported?(Support.Entities.Prompts.DslTest.Basic, :list, 0)
      assert function_exported?(Support.Entities.Prompts.DslTest.Basic, :get, 2)
    end
  end

  # -----------------------------------------------------------------------
  # list/0
  # -----------------------------------------------------------------------

  describe "list/0 (DSL modules)" do
    test "list/0 returns all declared prompts in order" do
      mod =
        module("PaginateDslFull") do
          prompt("first", title: "T", description: "D")
          prompt("second", title: "T", description: "D")
          prompt("third", title: "T", description: "D")
        end
        |> compile()

      names = fn prompts -> Enum.map(prompts, & &1.name) end

      assert names.(mod.list()) == ["first", "second", "third"]
    end
  end
end
