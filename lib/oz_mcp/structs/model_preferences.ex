defmodule OzMcp.Structs.ModelPreferences do
  @moduledoc """
  Helper module used to build `ModelPreferences` structure: what the server
  prefers when the client chooses a model. The client has the last word.

  _(MCP protocol: 2025-11-25)_

  `hints` is a list of model names (strings) or maps with a `name`. The
  priorities are numbers from `0` to `1`.

  ## Short example:

  ```elixir
  %ModelPreferences{}
    |> ModelPreferences.hints(["claude-3-sonnet"])
    |> ModelPreferences.intelligence_priority(0.8)
    |> ModelPreferences.build()
  ```

  Result:

  ```elixir
  %{hints: [%{name: "claude-3-sonnet"}], intelligencePriority: 0.8}
  ```

  Specification: [ModelPreferences](https://modelcontextprotocol.io/specification/2025-11-25/schema#modelpreferences)
  """

  use OzMcp.Structs.Wire,
    build: false,
    fields: [
      hints: {:list, type: quote(do: list(String.t() | map()) | nil)},
      costPriority: {:between, 0, 1},
      speedPriority: {:between, 0, 1},
      intelligencePriority: {:between, 0, 1}
    ]

  alias OzMcp.Structs.{Builder, Validate}

  @spec build(t()) :: map()
  def build(struct) do
    Validate.list_or_nil(:hints, struct.hints)
    Validate.number_between_or_nil(:costPriority, struct.costPriority, 0, 1)
    Validate.number_between_or_nil(:speedPriority, struct.speedPriority, 0, 1)
    Validate.number_between_or_nil(:intelligencePriority, struct.intelligencePriority, 0, 1)

    %{}
    |> put_hints(struct.hints)
    |> Builder.maybe_put(struct, :costPriority)
    |> Builder.maybe_put(struct, :speedPriority)
    |> Builder.maybe_put(struct, :intelligencePriority)
  end

  defp put_hints(result, nil), do: result
  defp put_hints(result, hints), do: Map.put(result, :hints, Enum.map(hints, &hint/1))

  defp hint(name) when is_binary(name) and name != "", do: %{name: name}
  defp hint(%{} = hint) when not is_struct(hint), do: hint

  defp hint(other) do
    raise ArgumentError,
          "'hints' elements must be non-empty strings or maps, got: #{inspect(other)}"
  end
end
