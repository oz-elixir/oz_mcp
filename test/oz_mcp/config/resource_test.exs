defmodule OzMcp.Config.ResourceTest do
  use ExUnit.Case, async: true
  import Support.Factories.Resource

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
          resource("doc.md", title: "Doc", description: "A doc")
        end
        |> compile()

      # The DSL auto-generates list/0.
      #
      assert function_exported?(mod, :list, 0)
    end

    test "dsl?: true explicitly activates the DSL" do
      mod =
        module("DslTrue", _dsl_: true) do
          resource("doc.md", title: "Doc", description: "A doc")
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
        resource("doc.md", title: "Doc", description: "A doc")
      end
      |> compile()
    end

    test "warn? option set to false is accepted" do
      module("WarnFalse") do
        resource("doc.md", title: "Doc", description: "A doc")
      end
      |> compile()
    end

    test "warn? option defaults to true" do
      module("DefaultWarnIsTrue", _warn_: :_none_) do
        resource("doc.md", description: "A doc")
      end
      |> assert_compile_warning("The resource doc.md does not have a title configuration")
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
  end

  # -----------------------------------------------------------------------
  # Behaviour conformance
  # -----------------------------------------------------------------------

  describe "behaviour callbacks" do
    test "declares the expected callbacks (complete/4 optional)" do
      callbacks = OzMcp.Config.Resource.behaviour_info(:callbacks)

      assert MapSet.new(callbacks) ==
               MapSet.new([
                 {:list, 0},
                 {:read, 2},
                 {:complete, 4}
               ])

      assert MapSet.new(OzMcp.Config.Resource.behaviour_info(:optional_callbacks)) ==
               MapSet.new(complete: 4)
    end

    # ----- DSL modules conform to the behaviour

    test "DSL modules implement list/0" do
      Code.ensure_loaded(Support.Entities.Resources.DslTest.Basic)
      assert function_exported?(Support.Entities.Resources.DslTest.Basic, :list, 0)
    end
  end

  # -----------------------------------------------------------------------
  # list/0
  # -----------------------------------------------------------------------

  describe "list/0 (DSL modules)" do
    test "list/0 returns all declared resources in order" do
      mod =
        module("PaginateDslFull") do
          resource("first.md", title: "T", description: "D")
          resource("second.md", title: "T", description: "D")
          resource("third.md", title: "T", description: "D")
        end
        |> compile()

      names = fn resources -> Enum.map(resources, & &1.name) end

      assert names.(mod.list()) == ["first.md", "second.md", "third.md"]
    end
  end
end
