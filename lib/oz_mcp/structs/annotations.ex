defmodule OzMcp.Structs.Annotations do
  @moduledoc """
  Helper module used to build `Annotations` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %Annotations{}
    |> Annotations.audience(["user", "assistant"])
    |> Annotations.priority(0.8)
    |> Annotations.last_modified("2025-01-12T15:00:58Z")
    |> Annotations.build()
  ```

  Result:

  ```elixir
  %{
    priority: 0.8,
    audience: ["user", "assistant"],
    lastModified: "2025-01-12T15:00:58Z"
  }
  ```

  Specification: [Annotations](https://modelcontextprotocol.io/specification/2025-11-25/schema#annotations)
  """

  use OzMcp.Structs.Wire,
    fields: [
      audience: {:any, check: :validate_audience, type: quote(do: [String.t()] | nil)},
      priority: {:any, check: :validate_priority, type: quote(do: number() | nil)},
      lastModified: {:string, also: :iso8601_or_nil}
    ]

  def build(struct) do
    if is_nil(struct.audience) and is_nil(struct.priority) and is_nil(struct.lastModified) do
      raise ArgumentError, "All fields are 'nil', remove annotations declaration"
    end

    super(struct)
  end

  @doc false
  @spec check(t()) :: :ok
  def check(%__MODULE__{} = struct) do
    if is_nil(struct.audience) and is_nil(struct.priority) and is_nil(struct.lastModified) do
      raise ArgumentError, "All fields are 'nil', remove annotations declaration"
    end

    check(struct.audience, struct.priority, struct.lastModified)
  end

  # A map with each member missing or nil passes: the block of a result
  # drops its unknown nested keys and goes to the client as it is.
  #
  @doc false
  @spec check(term(), term(), term()) :: :ok
  def check(nil, nil, nil), do: :ok

  def check(audience, priority, last_modified) do
    validate_audience(audience)
    validate_priority(priority)
    OzMcp.Structs.Validate.iso8601_or_nil(:lastModified, last_modified)
  end

  defp validate_audience(nil), do: :ok

  defp validate_audience(value) do
    cond do
      not is_list(value) ->
        raise ArgumentError, "'audience' must be a list, got: #{inspect(value)}"

      value == [] ->
        raise ArgumentError, "'audience' cannot be an empty list"

      not Enum.all?(value, &(&1 in OzMcp.Structs.Validate.roles())) ->
        raise ArgumentError,
              "'audience' elements must be \"user\" or \"assistant\", got: #{inspect(value)}"

      length(value) != length(Enum.uniq(value)) ->
        raise ArgumentError,
              "'audience' has duplicates elements, got: #{inspect(value)}"

      true ->
        :ok
    end
  end

  @doc """
  Checks a priority value. `nil` (not set) and each number from 0 to 1 are
  valid: 1 means most important, 0 means least important.

  Spec: `priority?: number`.
  """
  @spec validate_priority(term()) :: :ok
  def validate_priority(nil), do: :ok

  def validate_priority(value) when is_number(value) and value >= 0 and value <= 1, do: :ok

  def validate_priority(value) do
    raise ArgumentError,
          "'priority' must be a number between 0 and 1, got: #{inspect(value)}"
  end
end
