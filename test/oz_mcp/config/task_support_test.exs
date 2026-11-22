#
# Tests for the task rule of the tool modules and for the boot check of
# the task support of each static tool (OzMcp.Config.TaskSupport).
# See: lib/oz_mcp/config/task_support.ex
#
defmodule OzMcp.Config.TaskSupportTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  alias OzMcp.Config.TaskSupport
  alias Support.Helpers.Utils

  defmodule TaskRuleWarn do
    use OzMcp.Config.Tool

    tool "a" do
      title "A"
      description "A"
    end

    def call(_ctx, _params), do: {:error, :no_tool}
  end

  defmodule TaskRuleStrict do
    use OzMcp.Config.Tool, strict_tasks?: true

    tool "a" do
      title "A"
      description "A"
    end

    def call(_ctx, _params), do: {:error, :no_tool}
  end

  defmodule TaskRuleQuiet do
    use OzMcp.Config.Tool, warn?: false

    tool "a" do
      title "A"
      description "A"
    end

    def call(_ctx, _params), do: {:error, :no_tool}
  end

  defmodule TaskRuleMaps do
    use OzMcp.Config.Tool, dsl?: false

    def list, do: [%{"name" => "a"}]

    def call(_ctx, _params), do: {:error, :no_tool}
  end

  defmodule TaskRuleStrictQuiet do
    use OzMcp.Config.Tool, warn?: false, strict_tasks?: true

    tool "a" do
      title "A"
      description "A"
    end

    def call(_ctx, _params), do: {:error, :no_tool}
  end

  defmodule SlowTool do
    use OzMcp.Config.Tool

    tool "slow" do
      title "Slow"
      description "A tool that advertises an optional task support"

      execution do
        task_support "optional"
      end
    end

    def call(_ctx, _params), do: {:ok, %{content: []}}
  end

  defmodule SlowToolStrict do
    use OzMcp.Config.Tool, strict_tasks?: true

    tool "slow" do
      title "Slow"
      description "A tool that advertises an optional task support"

      execution do
        task_support "optional"
      end
    end

    def call(_ctx, _params), do: {:ok, %{content: []}}
  end

  defmodule SlowToolQuiet do
    use OzMcp.Config.Tool, warn?: false

    tool "slow" do
      title "Slow"
      description "A tool that advertises an optional task support"

      execution do
        task_support "optional"
      end
    end

    def call(_ctx, _params), do: {:ok, %{content: []}}
  end

  defmodule SlowToolRequired do
    use OzMcp.Config.Tool

    tool "slow" do
      title "Slow"
      description "A tool that advertises a required task support"

      execution do
        task_support "required"
      end
    end

    def call(_ctx, _params), do: {:ok, %{content: []}}
  end

  defmodule PlainTool do
    use OzMcp.Config.Tool

    tool "plain" do
      title "Plain"
      description "A tool with no execution block"
    end

    def call(_ctx, _params), do: {:ok, %{content: []}}
  end

  defmodule ForbiddenTool do
    use OzMcp.Config.Tool

    tool "forbidden" do
      title "Forbidden"
      description "A tool that advertises a forbidden task support"

      execution do
        task_support "forbidden"
      end
    end

    def call(_ctx, _params), do: {:ok, %{content: []}}
  end

  defmodule MapsSlowTool do
    use OzMcp.Config.Tool, dsl?: false

    alias OzMcp.Structs.{Tool, ToolExecution}

    def list do
      list = [
        %Tool{}
        |> Tool.name("slow")
        |> Tool.title("Slow")
        |> Tool.description("A tool that advertises an optional task support")
        |> Tool.execution(%ToolExecution{} |> ToolExecution.task_support(:optional))
      ]

      list
    end

    def call(_ctx, _params), do: {:error, :no_tool}
  end

  test "the task rule follows the options, for a DSL module" do
    assert TaskRuleWarn.__task_rule__() == :warn
    assert TaskRuleStrict.__task_rule__() == :strict
    assert TaskRuleQuiet.__task_rule__() == :off
  end

  test "a module with dsl?: false has a task rule too" do
    assert TaskRuleMaps.__task_rule__() == :warn
  end

  test "strict_tasks?: true wins over warn?: false" do
    assert TaskRuleStrictQuiet.__task_rule__() == :strict
  end

  test "the name rule of a DSL module does not change" do
    refute function_exported?(TaskRuleWarn, :__name_rule__, 0)
  end

  # -----
  # The boot check
  # -----

  defmacrop server_of(tool_module) do
    quote do
      module "TaskSupport" do
        tools do
          tool unquote(tool_module)
        end
      end
      |> compile()
    end
  end

  defmacrop server_of(tool_module, tasks_opts) do
    quote do
      module "TaskSupport" do
        capabilities do
          tasks(unquote(tasks_opts))
        end

        tools do
          tool unquote(tool_module)
        end
      end
      |> compile()
    end
  end

  test "a server without the capability logs one warning for the tool" do
    server = server_of(SlowTool)

    log = Utils.capture_log(fn -> assert TaskSupport.check!(server) == :ok end)

    assert log =~ inspect(SlowTool)
    assert log =~ ~s(tool "slow")
    assert log =~ ~s(execution.taskSupport "optional")
    assert length(Regex.scan(~r/tasks\.requests\.tools\.call/, log)) == 1
  end

  test "a tasks block without requests.tools.call gives the warning" do
    server = server_of(SlowTool, list: %{}, cancel: %{})

    log = Utils.capture_log(fn -> assert TaskSupport.check!(server) == :ok end)

    assert log =~ ~s(tool "slow")
    assert log =~ ~s(execution.taskSupport "optional")
  end

  test "a server with the capability logs nothing" do
    server = server_of(SlowTool, requests: %{tools: %{call: %{}}})

    log = Utils.capture_log(fn -> assert TaskSupport.check!(server) == :ok end)

    assert log == ""
  end

  test "the value required warns too" do
    server = server_of(SlowToolRequired)

    log = Utils.capture_log(fn -> assert TaskSupport.check!(server) == :ok end)

    assert log =~ ~s(tool "slow")
    assert log =~ ~s(execution.taskSupport "required")
  end

  test "forbidden and no execution log nothing" do
    plain = server_of(PlainTool)
    forbidden = server_of(ForbiddenTool)

    log =
      Utils.capture_log(fn ->
        assert TaskSupport.check!(plain) == :ok
        assert TaskSupport.check!(forbidden) == :ok
      end)

    assert log == ""
  end

  test "strict_tasks?: true raises an ArgumentError" do
    server = server_of(SlowToolStrict)

    assert_raise ArgumentError, ~r/tool "slow" has execution.taskSupport "optional"/, fn ->
      TaskSupport.check!(server)
    end
  end

  test "warn?: false logs nothing" do
    server = server_of(SlowToolQuiet)

    log = Utils.capture_log(fn -> assert TaskSupport.check!(server) == :ok end)

    assert log == ""
  end

  test "a dsl?: false module with a struct entity warns" do
    server = server_of(MapsSlowTool)

    log = Utils.capture_log(fn -> assert TaskSupport.check!(server) == :ok end)

    assert log =~ inspect(MapsSlowTool)
    assert log =~ ~s(tool "slow")
    assert log =~ ~s(execution.taskSupport "optional")
  end

  test "a server with no tools block logs nothing" do
    server =
      module "TaskSupportNoTools" do
        prompts do
          prompt(Support.Entities.Prompts.FirstTest)
        end
      end
      |> compile()

    log = Utils.capture_log(fn -> assert TaskSupport.check!(server) == :ok end)

    assert log == ""
  end

  test "parse!/1 logs the warning at boot" do
    server = server_of(SlowTool)

    log =
      Utils.capture_log(fn ->
        assert %OzMcp.Instance.Config{} =
                 OzMcp.Instance.Config.parse!(%{server: server, allowed_origins: []})
      end)

    assert log =~ inspect(SlowTool)
    assert log =~ ~s(tool "slow")
  end

  test "parse!/1 stops the boot with strict_tasks?: true" do
    server = server_of(SlowToolStrict)

    assert_raise ArgumentError, ~r/tool "slow"/, fn ->
      OzMcp.Instance.Config.parse!(%{server: server, allowed_origins: []})
    end
  end
end
