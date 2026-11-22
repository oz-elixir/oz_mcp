#
# Checks the result of a tool against the `outputSchema` of the tool.
#
# The synchronous `tools/call` and the runner of a task use the same
# check. A result that does not agree with the schema gives the error of
# `error/1`.
#
defmodule OzMcp.Handler.Output do
  @moduledoc false

  alias OzMcp.Catalog
  alias OzMcp.Utils.JsonSchemaValidator
  alias OzMcp.Wire

  @mismatch "tool output does not match outputSchema"
  @missing "'structuredContent' is missing, the tool declares an outputSchema"
  @not_object "'structuredContent' must be an object"

  # Returns the `outputSchema` of a tool, or `nil`.
  #
  @spec schema(struct() | nil) :: map() | nil
  def schema(nil), do: nil
  def schema(tool), do: tool.outputSchema

  # Returns the compiled root of the `outputSchema` of a tool, `{:ok, nil}`
  # when the tool declares no `outputSchema`, or `{:error, :invalid_schema}`.
  #
  # The root of a tool comes from the catalog of `server`. A root that the
  # catalog does not hold is compiled again.
  #
  @spec fetch_root(module(), module(), String.t(), map() | nil) ::
          {:ok, JSV.Root.t() | nil} | {:error, :invalid_schema}
  def fetch_root(_server, _tool_module, _tool_name, nil), do: {:ok, nil}

  def fetch_root(server, tool_module, tool_name, schema) do
    server
    |> Catalog.fetch()
    |> Catalog.fetch_root(tool_module, tool_name, :output, schema)
  end

  # Checks a built tool result. Returns `:ok` or `{:error, messages}`.
  #
  # A result that reports a tool execution error is not checked. Each other
  # result must carry a `structuredContent` that is an object and that agrees
  # with the schema. The check validates the wire form of the value: atom keys
  # and atom values are strings, as on the wire.
  #
  @spec check(JSV.Root.t() | nil, term()) :: :ok | {:error, [String.t()]}
  def check(nil, _result), do: :ok

  def check(root, result) when is_map(result) do
    if error_result?(result) do
      :ok
    else
      case structured_content(result) do
        :error -> {:error, [@missing]}
        {:ok, nil} -> {:error, [@missing]}
        {:ok, data} when is_map(data) -> validate(root, Wire.to_wire(data))
        {:ok, _other} -> {:error, [@not_object]}
      end
    end
  end

  def check(_root, _result), do: {:error, [@missing]}

  # True when the result reports a tool execution error.
  #
  @spec error_result?(map()) :: boolean()
  def error_result?(result), do: Map.get(result, :isError) == true

  # The error of a result that does not agree with the schema.
  #
  @spec error([String.t()]) :: %{code: integer(), message: String.t(), data: [String.t()]}
  def error(messages), do: %{code: -32603, message: @mismatch, data: messages}

  defp validate(root, data) do
    case JsonSchemaValidator.validate(root, data) do
      {:ok, _data} -> :ok
      {:error, messages} -> {:error, messages}
    end
  end

  defp structured_content(result), do: Map.fetch(result, :structuredContent)
end
