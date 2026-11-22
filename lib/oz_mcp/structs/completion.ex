defmodule OzMcp.Structs.Completion do
  @moduledoc """
  Helper module used to build the `Completion` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %Completion{}
    |> Completion.values(["python", "pytorch", "pyside"])
    |> Completion.build()
  ```

  Result:

  ```elixir
  %{values: ["python", "pytorch", "pyside"]}
  ```

  ## Long example:

  ```elixir
  %Completion{}
    |> Completion.values(["python", "pytorch", "pyside"])
    |> Completion.total(10)
    |> Completion.has_more(true)
    |> Completion.build()
  ```

  Result:

  ```elixir
  %{values: ["python", "pytorch", "pyside"], total: 10, hasMore: true}
  ```

  Specification: [Completion](https://modelcontextprotocol.io/specification/2025-11-25/schema#completion)
  """

  use OzMcp.Structs.Wire,
    fields: [
      values: {:list, required: true},
      total: :non_neg_integer,
      hasMore: :boolean
    ]

  alias OzMcp.Structs.{Keys, Validate}

  def build(struct) do
    result = super(struct)
    Validate.completion_values(struct.values)
    result
  end

  @doc false
  @spec check_map(map()) :: :ok
  def check_map(%{} = completion) do
    Validate.completion_values(Keys.get(completion, "values", :values, nil))
    Validate.non_neg_integer_or_nil(:total, Keys.get(completion, "total", :total, nil))
    Validate.boolean_or_nil(:hasMore, Keys.get(completion, "hasMore", :hasMore, nil))
  end
end
