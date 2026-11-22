#
# Boot check: the name of each tool of a module with `dsl?: false`
# follows the rule of the tool names. The compiler already checks the
# names of the DSL modules. The option of the module gives the answer
# to a bad name: a refusal (`strict_names?: true`), a warning in the
# log (the default), or nothing (`warn?: false`).
#
defmodule OzMcp.Config.ToolNames do
  @moduledoc false

  alias OzMcp.Catalog
  alias OzMcp.Config.DSL.Rules

  require Logger

  @spec check!(module()) :: :ok
  def check!(server) do
    config =
      if Code.ensure_loaded?(server) and function_exported?(server, :config, 0),
        do: server.config(),
        else: %{}

    case Map.get(config, :tools) do
      %{modules: modules} -> Enum.each(modules, &check_module!/1)
      _no_block -> :ok
    end
  end

  defp check_module!(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__name_rule__, 0) do
      check_names!(module, module.__name_rule__())
    end

    :ok
  end

  defp check_names!(_module, :off), do: :ok

  defp check_names!(module, rule) do
    for %{key: name} <- Catalog.entries(module, :tools),
        {:error, message} <- [Rules.tool_name(name)] do
      report(rule, "#{inspect(module)}: tool name #{message}")
    end

    :ok
  end

  defp report(:strict, message), do: raise(ArgumentError, message)
  defp report(:warn, message), do: Logger.warning(message)
end
