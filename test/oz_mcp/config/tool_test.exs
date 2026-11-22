defmodule OzMcp.Config.ToolTest do
  use ExUnit.Case, async: true
  import Support.Factories.Tool

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
          tool("get_date", title: "T", description: "D")
        end
        |> compile()

      # The DSL auto-generates list/0.
      #
      assert function_exported?(mod, :list, 0)
    end

    test "dsl?: true explicitly activates the DSL" do
      mod =
        module("DslTrue", _dsl_: true) do
          tool("get_date", title: "T", description: "D")
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
        tool("get_date", title: "T", description: "D")
      end
      |> compile()
    end

    test "warn? option set to false is accepted" do
      module("WarnFalse") do
        tool("get_date", title: "T", description: "D")
      end
      |> compile()
    end

    test "warn? option defaults to true" do
      module("DefaultWarnIsTrue", _warn_: :_none_) do
        tool("get_date", description: "D")
      end
      |> assert_compile_warning("The tool get_date does not have a title configuration")
    end

    # -----------------------------------------------------------------------
    # strict_names? option
    # -----------------------------------------------------------------------

    test "raises when strict_names? option is not a boolean" do
      module("StrictNotBoolean", _strict_names_: "yes")
      |> assert_compile_raise(ArgumentError, "strict_names? option must be a boolean")
    end

    test "strict_names? option set to true is accepted" do
      module("StrictTrue", _strict_names_: true) do
        tool("get_date", title: "T", description: "D")
      end
      |> compile()
    end

    test "strict_names? option defaults to false (no error for a name outside the rule)" do
      module("StrictDefault", _strict_names_: :_none_, _warn_: false) do
        tool("get date", title: "T", description: "D")
      end
      |> compile()
    end

    # -----------------------------------------------------------------------
    # strict_tasks? option
    # -----------------------------------------------------------------------

    test "raises when strict_tasks? option is not a boolean" do
      module("StrictTasksNotBoolean", _strict_tasks_: "yes")
      |> assert_compile_raise(ArgumentError, "strict_tasks? option must be a boolean")
    end

    test "strict_tasks? option set to true is accepted" do
      mod =
        module("StrictTasksTrue", _strict_tasks_: true) do
          tool("get_date", title: "T", description: "D")
        end
        |> compile()

      assert mod.__task_rule__() == :strict
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
      module("NoList", _dsl_: false)
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

    test "raises when call/2 is not defined (call/1 no longer satisfies the behaviour)" do
      code =
        quote do
          def list, do: []
          def call(_params), do: {:error, :no_tool}
        end

      module("OldCallArity", _dsl_: false, _call_: :_none_, _code_: code)
      |> assert_compile_raise(
        RuntimeError,
        "you must satisfy the call/2 behaviour"
      )
    end

    test "raises when call is not defined at all" do
      code =
        quote do
          def list, do: []
        end

      module("NoCall", _dsl_: false, _call_: :_none_, _code_: code)
      |> assert_compile_raise(
        RuntimeError,
        "you must satisfy the call/2 behaviour"
      )
    end
  end

  # -----------------------------------------------------------------------
  # Behaviour conformance
  # -----------------------------------------------------------------------

  describe "behaviour callbacks" do
    test "declares the expected callbacks" do
      callbacks = OzMcp.Config.Tool.behaviour_info(:callbacks)

      assert MapSet.new(callbacks) ==
               MapSet.new([
                 {:list, 0},
                 {:call, 2}
               ])
    end

    # ----- DSL modules conform to the behaviour

    test "DSL modules implement all required callbacks" do
      Code.ensure_loaded(Support.Entities.Tools.DslTest.Basic)
      assert function_exported?(Support.Entities.Tools.DslTest.Basic, :list, 0)
      assert function_exported?(Support.Entities.Tools.DslTest.Basic, :call, 2)
    end
  end

  # -----------------------------------------------------------------------
  # list/0
  # -----------------------------------------------------------------------

  describe "list/0 (DSL modules)" do
    test "list/0 returns all declared tools in order" do
      mod =
        module("PaginateDslFull") do
          tool("first", title: "T", description: "D")
          tool("second", title: "T", description: "D")
          tool("third", title: "T", description: "D")
        end
        |> compile()

      names = fn tools -> Enum.map(tools, & &1.name) end

      assert names.(mod.list()) == ["first", "second", "third"]
    end
  end
end
