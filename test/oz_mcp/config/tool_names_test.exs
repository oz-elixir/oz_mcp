#
# Tests for the boot check of the tool names of the modules with
# `dsl?: false` (OzMcp.Config.ToolNames).
# See: lib/oz_mcp/config/tool_names.ex
#
defmodule OzMcp.Config.ToolNamesTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  alias OzMcp.Config.ToolNames
  alias Support.Helpers.Utils

  defmodule BadNameWarn do
    use OzMcp.Config.Tool, dsl?: false

    def list, do: [%{"name" => "bad name"}]

    def call(_ctx, _params), do: {:error, :no_tool}
  end

  defmodule BadNameStrict do
    use OzMcp.Config.Tool, dsl?: false, strict_names?: true

    def list, do: [%{"name" => "bad name"}]

    def call(_ctx, _params), do: {:error, :no_tool}
  end

  defmodule BadNameQuiet do
    use OzMcp.Config.Tool, dsl?: false, warn?: false

    def list, do: [%{"name" => "bad name"}]

    def call(_ctx, _params), do: {:error, :no_tool}
  end

  defmodule BadNameDsl do
    use OzMcp.Config.Tool, warn?: false

    tool "bad name" do
      title "Bad name"
      description "A name outside the rule"
    end

    def call(_ctx, _params), do: {:error, :no_tool}
  end

  defmacrop server_of(tool_module) do
    quote do
      module "ToolNames" do
        tools do
          tool unquote(tool_module)
        end
      end
      |> compile()
    end
  end

  test "a bad name logs a warning with the default options" do
    server = server_of(BadNameWarn)

    log = Utils.capture_log(fn -> assert ToolNames.check!(server) == :ok end)

    assert log =~ "#{inspect(BadNameWarn)}: tool name must be 1 to 128 characters"
    assert log =~ ~s("bad name")
  end

  test "a bad name raises with strict_names?: true" do
    server = server_of(BadNameStrict)

    assert_raise ArgumentError, ~r/#{inspect(BadNameStrict)}: tool name must be 1 to 128/, fn ->
      ToolNames.check!(server)
    end
  end

  test "a bad name logs nothing with warn?: false" do
    server = server_of(BadNameQuiet)

    log = Utils.capture_log(fn -> assert ToolNames.check!(server) == :ok end)

    assert log == ""
  end

  test "a good name logs nothing" do
    server = server_of(Support.Entities.Tools.SecondTest)

    log = Utils.capture_log(fn -> assert ToolNames.check!(server) == :ok end)

    assert log == ""
  end

  test "a DSL module has no rule function and is not checked at boot" do
    refute function_exported?(BadNameDsl, :__name_rule__, 0)

    server = server_of(BadNameDsl)

    log = Utils.capture_log(fn -> assert ToolNames.check!(server) == :ok end)

    assert log == ""
  end

  test "the rule of a module with dsl?: false follows its options" do
    assert BadNameWarn.__name_rule__() == :warn
    assert BadNameStrict.__name_rule__() == :strict
    assert BadNameQuiet.__name_rule__() == :off
  end

  test "the boot of an instance runs the check" do
    warn = server_of(BadNameWarn)
    strict = server_of(BadNameStrict)

    log =
      Utils.capture_log(fn ->
        assert %OzMcp.Instance.Config{} =
                 OzMcp.Instance.Config.parse!(%{server: warn, allowed_origins: []})
      end)

    assert log =~ "#{inspect(BadNameWarn)}: tool name"

    assert_raise ArgumentError, ~r/#{inspect(BadNameStrict)}: tool name/, fn ->
      OzMcp.Instance.Config.parse!(%{server: strict, allowed_origins: []})
    end
  end
end
