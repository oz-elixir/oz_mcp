defmodule OzMcp.Method.Capabilities do
  @moduledoc false

  import OzMcp.Pipeline.Helpers, only: [deep: 2, tasks_capability_of: 1]

  # One check for each gate atom of `OzMcp.Method`. Every refused gate
  # gives the same error (`rpc_method_not_found`), so the order of the
  # gates does not change the result.
  #

  @spec allowed?([OzMcp.Method.gate()], map()) :: boolean()
  def allowed?(gates, config), do: Enum.all?(gates, &gate(&1, config))

  defp gate(:tools, %{tools: tools}), do: not is_nil(tools)

  defp gate(:prompts, %{prompts: prompts}), do: not is_nil(prompts)

  defp gate(:resources, %{resources: resources}), do: not is_nil(resources)

  defp gate(:resources_subscribe, %{capabilities: capabilities}) do
    resources = if capabilities, do: capabilities.resources, else: nil

    resources != nil and resources[:subscribe] == true
  end

  defp gate(:logging, %{capabilities: capabilities}) do
    logging = if capabilities, do: capabilities.logging, else: nil

    logging != nil
  end

  defp gate(:completions, %{capabilities: capabilities}) do
    completions =
      if capabilities,
        do: Map.get(capabilities, :completions) || Map.get(capabilities, "completions"),
        else: nil

    not is_nil(completions)
  end

  defp gate(:tasks, %{capabilities: capabilities}) do
    not is_nil(tasks_capability_of(capabilities))
  end

  defp gate(:tasks_list, %{capabilities: capabilities}), do: cap_member?(capabilities, :list)

  defp gate(:tasks_cancel, %{capabilities: capabilities}), do: cap_member?(capabilities, :cancel)

  defp cap_member?(capabilities, key), do: deep(tasks_capability_of(capabilities), [key]) != nil
end
