defmodule OzMcp.Structs.CompleteResult do
  @moduledoc """
  Helper module used to build the `CompleteResult` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %CompleteResult{}
    |> CompleteResult.completion(
      %Completion{}
      |> Completion.values(["python", "pytorch"])
    )
    |> CompleteResult.build()
  ```

  Result:

  ```elixir
  %{completion: %{values: ["python", "pytorch"]}}
  ```

  Specification: [CompleteResult](https://modelcontextprotocol.io/specification/2025-11-25/schema#completeresult)
  """

  use OzMcp.Structs.Wire,
    build: false,
    fields: [
      completion:
        {:any, required: true, type: quote(do: OzMcp.Structs.Completion.t() | map() | nil)},
      _meta: :meta
    ]

  alias OzMcp.Structs.{Builder, Completion, Validate}

  @spec build(t()) :: map()
  def build(%__MODULE__{completion: %Completion{} = completion} = struct) do
    Validate.meta(:_meta, struct._meta)

    %{completion: Completion.build(completion)}
    |> Builder.maybe_meta(struct)
  end

  def build(%__MODULE__{completion: completion} = struct) when is_map(completion) do
    Validate.meta(:_meta, struct._meta)
    Completion.check_map(completion)

    %{completion: completion}
    |> Builder.maybe_meta(struct)
  end

  def build(%__MODULE__{}) do
    raise ArgumentError,
          "The 'completion' field is required and must be a OzMcp.Structs.Completion struct or a map"
  end
end
