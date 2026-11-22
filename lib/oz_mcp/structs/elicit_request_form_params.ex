defmodule OzMcp.Structs.ElicitRequestFormParams do
  @moduledoc """
  Helper module used to build the params of an `elicitation/create` request
  in form mode.

  _(MCP protocol: 2025-11-25)_

  `requestedSchema` is a `OzMcp.Structs.ElicitationSchema` struct or a map
  that is already a schema.

  ## Short example:

  ```elixir
  %ElicitRequestFormParams{}
    |> ElicitRequestFormParams.message("Which name?")
    |> ElicitRequestFormParams.requested_schema(schema)
    |> ElicitRequestFormParams.build()
  ```

  Result:

  ```elixir
  %{mode: "form", message: "Which name?", requestedSchema: %{type: "object", ...}}
  ```

  Specification: [ElicitRequestFormParams](https://modelcontextprotocol.io/specification/2025-11-25/schema#elicitrequestformparams)
  """

  use OzMcp.Structs.Wire,
    build: false,
    const: %{mode: "form"},
    fields: [
      message: {:string, required: true},
      requestedSchema:
        {:any, required: true, type: quote(do: OzMcp.Structs.ElicitationSchema.t() | map() | nil)},
      _meta: :meta,
      task: {:struct, OzMcp.Structs.TaskMetadata}
    ]

  alias OzMcp.Structs.{Builder, ElicitationSchema, Validate}

  @spec build(t()) :: map()
  def build(struct) do
    Validate.non_empty_string(:message, struct.message)
    Validate.meta(:_meta, struct._meta)
    Validate.struct_or_nil(:task, OzMcp.Structs.TaskMetadata, struct.task)

    %{mode: "form", message: struct.message}
    |> Map.put(:requestedSchema, schema(struct.requestedSchema))
    |> Builder.maybe_meta(struct)
    |> put_task(struct)
  end

  defp put_task(result, %{task: nil}), do: result

  defp put_task(result, struct) do
    Map.put(result, :task, OzMcp.Structs.TaskMetadata.build(struct.task))
  end

  defp schema(%ElicitationSchema{} = schema), do: ElicitationSchema.build(schema)
  defp schema(%{} = schema) when not is_struct(schema), do: schema

  defp schema(other) do
    raise ArgumentError,
          "The 'requestedSchema' field is required and must be an ElicitationSchema struct " <>
            "or a map, got: #{inspect(other)}"
  end
end
