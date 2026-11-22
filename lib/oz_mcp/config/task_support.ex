#
# Boot check: a tool that advertises `execution.taskSupport`
# "optional" or "required" needs `tasks.requests.tools.call` in the
# capabilities of the server. Without it, the server drops the `task`
# member of each call and runs a plain call (see `Pipeline.Bind`), so
# `tools/list` promises a mode that the server never runs. The rule of
# the module gives the answer: a refusal (`strict_tasks?: true`), a
# warning in the log (the default), or nothing (`warn?: false`).
#
defmodule OzMcp.Config.TaskSupport do
  @moduledoc false

  import OzMcp.Pipeline.Helpers,
    only: [task_support_of: 1, tasks_capability_of: 1, tools_call_task_capable?: 1]

  alias OzMcp.Catalog

  require Logger

  @spec check!(module()) :: :ok
  def check!(server) do
    config =
      if Code.ensure_loaded?(server) and function_exported?(server, :config, 0),
        do: server.config(),
        else: %{}

    capable? =
      config
      |> Map.get(:capabilities)
      |> tasks_capability_of()
      |> tools_call_task_capable?()

    case {capable?, Map.get(config, :tools)} do
      {false, %{modules: modules}} -> Enum.each(modules, &check_module!(server, &1))
      _capable_or_no_block -> :ok
    end
  end

  defp check_module!(server, module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__task_rule__, 0) do
      check_tools!(server, module, module.__task_rule__())
    end

    :ok
  end

  defp check_tools!(_server, _module, :off), do: :ok

  defp check_tools!(server, module, rule) do
    for %{key: name, entity: entity} <- Catalog.entries(module, :tools),
        value <- [task_support_of(entity)],
        value in [:optional, :required] do
      report(rule, message(server, module, name, value))
    end

    :ok
  end

  defp message(server, module, name, value) do
    "#{inspect(server)}: #{inspect(module)}: tool #{inspect(name)} has " <>
      "execution.taskSupport #{inspect(to_string(value))}, but the server has no " <>
      "tasks.requests.tools.call capability. tools/list shows a mode that " <>
      "the server never runs. Add `requests %{tools: %{call: %{}}}` to the " <>
      "tasks capability, or set `task_support \"forbidden\"`."
  end

  defp report(:strict, message), do: raise(ArgumentError, message)
  defp report(:warn, message), do: Logger.warning(message)
end
