#
# Helper module used to build result maps from the `OzMcp.Structs`
# structs. It gives the shared conditional-put helpers (`nil` aware) of
# the `build/1` functions of the structure modules.
#
defmodule OzMcp.Structs.Builder do
  @moduledoc false

  alias OzMcp.Structs.{
    Annotations,
    AudioContent,
    ContentBlock,
    EmbeddedResource,
    ImageContent,
    ResourceLink,
    TextContent,
    Validate
  }

  @spec content(ContentBlock.t()) :: map()
  def content(%TextContent{} = c), do: TextContent.build(c)
  def content(%ImageContent{} = c), do: ImageContent.build(c)
  def content(%AudioContent{} = c), do: AudioContent.build(c)
  def content(%ResourceLink{} = c), do: ResourceLink.build(c)
  def content(%EmbeddedResource{} = c), do: EmbeddedResource.build(c)
  def content(%{} = c), do: c

  # @spec maybe_put(map(), map(), atom(), String.t() | nil) :: map()
  #
  @spec maybe_put(map(), map(), atom(), String.t() | atom() | nil) :: map()
  def maybe_put(result, struct, field, key \\ nil) do
    case Map.fetch!(struct, field) do
      nil ->
        result

      value ->
        if is_nil(key) do
          Map.put(result, field, value)
        else
          Map.put(result, key, value)
        end
    end
  end

  @spec maybe_annotations(map(), map()) :: map()
  def maybe_annotations(result, %{annotations: nil} = _struct), do: result

  def maybe_annotations(result, struct) do
    Map.put(result, :annotations, Annotations.build(struct.annotations))
  end

  @spec maybe_meta(map(), map()) :: map()
  def maybe_meta(result, struct), do: maybe_put(result, struct, :_meta)

  # Builds the result of a paginated list. An item is a `module` struct or a
  # map. The key of the items and `nextCursor` win over an extra of the same
  # name, also when the cursor is `nil`.
  #
  @spec page(atom(), module(), list(), String.t() | nil, map() | nil, map() | nil) :: map()
  def page(key, module, items, cursor, meta \\ nil, extras \\ nil) do
    Validate.list(key, items)
    Validate.non_empty_string_or_nil(:nextCursor, cursor)
    Validate.meta(:_meta, meta)
    Validate.map_or_nil(:extras, extras)

    built =
      Enum.map(items, fn
        %^module{} = item -> module.build(item)
        item when is_map(item) -> item
      end)

    %{key => built}
    |> put_present(:nextCursor, cursor)
    |> put_present(:_meta, meta)
    |> merge_extras(extras, [key, :nextCursor, :_meta])
  end

  # Merges the extras into the result.
  #
  # The keys are compared as strings: `:protocolVersion` and
  # `"protocolVersion"` are the same JSON key. A key of the result or a field
  # of the struct (also a field with the value `nil`, such as `nextCursor` on
  # the last page) wins over an extra with the same name. The extra is then
  # dropped. Thus the JSON object never has two keys with the same name.
  #
  @spec maybe_extras(map(), map()) :: map()
  def maybe_extras(result, %{extras: nil} = _struct), do: result

  def maybe_extras(result, struct) do
    fields = struct |> Map.drop([:__struct__, :extras]) |> Map.keys()
    merge_extras(result, struct.extras, fields)
  end

  @spec merge_extras(map(), map() | nil, [atom()]) :: map()
  def merge_extras(result, nil, _fields), do: result
  def merge_extras(result, extras, _fields) when extras == %{}, do: result

  def merge_extras(result, extras, fields) do
    taken = fields |> Enum.concat(Map.keys(result)) |> MapSet.new(&to_string/1)

    {result, _taken} =
      Enum.reduce(extras, {result, taken}, fn {key, value}, {acc, taken} ->
        name = to_string(key)

        if MapSet.member?(taken, name) do
          {acc, taken}
        else
          {Map.put(acc, key, value), MapSet.put(taken, name)}
        end
      end)

    result
  end

  defp put_present(result, _key, nil), do: result
  defp put_present(result, key, value), do: Map.put(result, key, value)
end
