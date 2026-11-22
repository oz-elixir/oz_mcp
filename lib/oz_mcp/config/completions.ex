#
# Boot check: the `completions` capability of the server and the
# optional `complete/4` callback of its prompt, template and resource
# modules must match.
#
# The capability without a callback names a server that can never
# answer `completion/complete`: the boot stops. A callback without
# the capability is not reachable (the method gives the error
# `-32601` when the capability is absent): the boot logs a warning.
#
# The check reads the constant config of the server and never calls
# `list/0`. It uses `Code.ensure_loaded?/1` and `function_exported?/3`
# for each module, so a module that is not loaded is skipped.
#
defmodule OzMcp.Config.Completions do
  @moduledoc false

  require Logger

  @spec check!(module()) :: :ok
  def check!(server) do
    config = server_config(server)
    declared? = declared?(config)
    implemented? = implemented?(config)

    cond do
      declared? and not implemented? ->
        raise ArgumentError,
              "server #{inspect(server)} declares the completions capability, " <>
                "but no prompt module, no template module and no resource module " <>
                "defines complete/4"

      implemented? and not declared? ->
        Logger.warning(
          "server #{inspect(server)} has a module with complete/4, but it does not " <>
            "declare the completions capability: the clients will not send " <>
            "completion/complete"
        )

        :ok

      true ->
        :ok
    end
  end

  defp server_config(server) do
    if Code.ensure_loaded?(server) and function_exported?(server, :config, 0),
      do: server.config(),
      else: %{}
  end

  defp declared?(config) do
    case Map.get(config, :capabilities) do
      nil -> false
      capabilities -> not is_nil(Map.get(capabilities, :completions))
    end
  end

  defp implemented?(config) do
    [:prompts, :templates, :resources]
    |> Enum.flat_map(fn kind ->
      case Map.get(config, kind) do
        nil -> []
        block -> Map.get(block, :modules, [])
      end
    end)
    |> Enum.any?(&(Code.ensure_loaded?(&1) and function_exported?(&1, :complete, 4)))
  end
end
