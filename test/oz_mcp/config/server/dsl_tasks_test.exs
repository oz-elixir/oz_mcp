#
# Tests for the `tasks/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLTasksTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "tasks/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a tasks block with list, cancel and requests" do
      config =
        module("Tasks") do
          capabilities do
            tasks do
              list %{a: 1}
              cancel %{b: 2}
              requests %{tools: %{call: %{}}}
            end
          end
        end
        |> compile_config()

      assert config.capabilities.tasks == %{
               list: %{a: 1},
               cancel: %{b: 2},
               requests: %{tools: %{call: %{}}}
             }
    end

    test "drops nil members for a partial tasks block" do
      config =
        module("Tasks") do
          capabilities do
            tasks do
              list %{a: 1}
            end
          end
        end
        |> compile_config()

      assert config.capabilities.tasks == %{list: %{a: 1}}
    end

    test "accepts empty-object members" do
      config =
        module("Tasks") do
          capabilities do
            tasks do
              list %{}
              cancel %{}
              requests %{}
            end
          end
        end
        |> compile_config()

      assert config.capabilities.tasks == %{list: %{}, cancel: %{}, requests: %{}}
    end

    test "declares an empty capability map for an empty tasks block" do
      config =
        module("Tasks") do
          capabilities do
            tasks()
          end
        end
        |> compile_config()

      assert config.capabilities.tasks == %{}
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when tasks is declared multiple times" do
      module("Tasks") do
        capabilities do
          tasks(list: %{a: 1})
          tasks(list: %{b: 2})
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'tasks' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when tasks is used at root level" do
      module("Tasks") do
        tasks(list: %{a: 1})
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Tasks",
        "undefined function tasks/1"
      )
    end

    test "raises when tasks is used inside tools block" do
      module("Tasks") do
        tools do
          tasks(list: %{a: 1})
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'tasks' here")
    end
  end
end
