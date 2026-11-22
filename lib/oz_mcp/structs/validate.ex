#
# Helper module used to validate the fields of the `OzMcp.Structs`
# structs. Each validator raises an `ArgumentError` when the value is
# invalid and returns `:ok` otherwise.
#
defmodule OzMcp.Structs.Validate do
  @moduledoc false

  alias OzMcp.Config.DSL.Rules

  alias OzMcp.Structs.{
    Annotations,
    AudioContent,
    BlobResourceContents,
    ContentBlock,
    EmbeddedResource,
    Icon,
    ImageContent,
    Keys,
    Nested,
    ResourceLink,
    Task,
    TextContent,
    TextResourceContents
  }

  @roles ["user", "assistant", :user, :assistant]

  @spec roles() :: list()
  def roles, do: @roles

  @spec non_empty_string(atom(), term()) :: :ok
  def non_empty_string(_field, value) when is_binary(value) and value != "", do: :ok

  def non_empty_string(field, value) when not is_binary(value) do
    raise ArgumentError, "The '#{Atom.to_string(field)}' field is required and must be a string"
  end

  def non_empty_string(field, _value) do
    raise ArgumentError, "The '#{Atom.to_string(field)}' field cannot be an empty string"
  end

  @spec non_empty_string_or_nil(atom(), term()) :: :ok
  def non_empty_string_or_nil(_field, value) when is_binary(value) and value != "", do: :ok
  def non_empty_string_or_nil(_field, nil), do: :ok

  def non_empty_string_or_nil(field, value) when not is_binary(value) do
    raise ArgumentError, "The '#{Atom.to_string(field)}' field must be a string or nil"
  end

  def non_empty_string_or_nil(field, _value) do
    raise ArgumentError, "The '#{Atom.to_string(field)}' field cannot be an empty string"
  end

  @spec string_or_nil(atom(), term()) :: :ok
  def string_or_nil(_field, nil), do: :ok
  def string_or_nil(_field, value) when is_binary(value), do: :ok

  def string_or_nil(field, _value) do
    raise ArgumentError, "The '#{Atom.to_string(field)}' field must be a string or nil"
  end

  @spec one_of(atom(), term(), list(term())) :: :ok
  def one_of(field, value, allowed) do
    if value in allowed do
      :ok
    else
      raise ArgumentError,
            "The '#{Atom.to_string(field)}' field must be one of #{inspect(allowed)}"
    end
  end

  @spec non_neg_integer_or_nil(atom(), term()) :: :ok
  def non_neg_integer_or_nil(_field, value) when is_integer(value) and value >= 0, do: :ok
  def non_neg_integer_or_nil(_field, nil), do: :ok

  def non_neg_integer_or_nil(field, _value) do
    raise ArgumentError,
          "The '#{Atom.to_string(field)}' field must be a non-negative integer or nil"
  end

  @spec number_or_nil(atom(), term()) :: :ok
  def number_or_nil(field, value) do
    if is_number(value) or is_nil(value) do
      :ok
    else
      raise ArgumentError,
            "The '#{Atom.to_string(field)}' field must be a number or nil"
    end
  end

  @spec number_between_or_nil(atom(), term(), number(), number()) :: :ok
  def number_between_or_nil(field, value, min, max) do
    if is_nil(value) or (is_number(value) and value >= min and value <= max) do
      :ok
    else
      raise ArgumentError,
            "The '#{Atom.to_string(field)}' field must be a number between #{min} and #{max} or nil"
    end
  end

  @spec one_of_or_nil(atom(), term(), list(term())) :: :ok
  def one_of_or_nil(_field, nil, _allowed), do: :ok
  def one_of_or_nil(field, value, allowed), do: one_of(field, value, allowed)

  @spec boolean_or_nil(atom(), term()) :: :ok
  def boolean_or_nil(_field, value) when is_boolean(value) or is_nil(value), do: :ok

  def boolean_or_nil(field, _value) do
    raise ArgumentError,
          "The '#{Atom.to_string(field)}' field must be a boolean or nil"
  end

  @spec map_or_nil(atom(), term()) :: :ok
  def map_or_nil(_field, value) when is_map(value) or is_nil(value), do: :ok

  def map_or_nil(field, _value) do
    raise ArgumentError,
          "The '#{Atom.to_string(field)}' field must be a map or nil"
  end

  @spec map(atom(), term()) :: :ok
  def map(_field, value) when is_map(value), do: :ok

  def map(field, _value) do
    raise ArgumentError, "The '#{Atom.to_string(field)}' field is required and must be a map"
  end

  # A `_meta` map that server code writes, with the key format of the specification.
  #
  @spec meta(atom(), term()) :: :ok
  def meta(_field, nil), do: :ok

  def meta(field, value) do
    map_or_nil(field, value)
    check(field, Rules.meta_keys(value))
  end

  @spec list(atom(), term()) :: :ok
  def list(field, value) do
    if proper?(value) do
      :ok
    else
      raise ArgumentError, "The '#{Atom.to_string(field)}' field must be a list"
    end
  end

  @spec list_or_nil(atom(), term()) :: :ok
  def list_or_nil(_field, value) when is_list(value) or is_nil(value), do: :ok

  def list_or_nil(field, _value) do
    raise ArgumentError,
          "The '#{Atom.to_string(field)}' field must be a list or nil"
  end

  # A JSON schema of an input. The empty map is the default object schema.
  #
  @spec input_schema(term()) :: :ok
  def input_schema(value) when value == %{}, do: :ok
  def input_schema(value), do: check(:inputSchema, Rules.object_schema(value))

  # A JSON schema of an output, or `nil` when the tool gives no output.
  #
  @spec output_schema_or_nil(term()) :: :ok
  def output_schema_or_nil(nil), do: :ok
  def output_schema_or_nil(value), do: check(:outputSchema, Rules.object_schema(value))

  # An ISO 8601 date and time with an offset, or `nil`.
  #
  @spec iso8601_or_nil(atom(), term()) :: :ok
  def iso8601_or_nil(_field, nil), do: :ok
  def iso8601_or_nil(field, value), do: check(field, Rules.iso8601(value))

  # An absolute URI with a scheme.
  #
  @spec absolute_uri(atom(), term()) :: :ok
  def absolute_uri(field, value) do
    case Rules.absolute_uri(value) do
      :ok -> :ok
      {:error, message} -> raise(ArgumentError, "The '#{field}' field #{message}")
    end
  end

  # The source of an icon: an `https:` URL, an `http:` URL of a loopback host, or a `data:` URI.
  #
  @spec icon_src(atom(), term()) :: :ok
  def icon_src(field, value), do: check(field, Rules.icon_src(value))

  # The sizes of an icon, or `nil`. Each entry is "any" or a "WxH" string.
  #
  @spec icon_sizes_or_nil(atom(), term()) :: :ok
  def icon_sizes_or_nil(_field, nil), do: :ok
  def icon_sizes_or_nil(field, sizes), do: Enum.each(sizes, &check(field, Rules.icon_size(&1)))

  defp check(_field, :ok), do: :ok

  defp check(field, {:error, message}),
    do: raise(ArgumentError, "The '#{field}' field #{message}")

  defp proper?([_ | tail]), do: proper?(tail)
  defp proper?([]), do: true
  defp proper?(_other), do: false

  @spec struct(atom(), module(), term()) :: :ok
  def struct(field, struct_module, value) do
    if is_struct(value, struct_module) do
      :ok
    else
      raise ArgumentError,
            "The '#{Atom.to_string(field)}' field is required and must be a #{inspect(struct_module)} struct"
    end
  end

  @spec struct_or_nil(atom(), module(), term()) :: :ok
  def struct_or_nil(field, struct_module, value) do
    if is_struct(value, struct_module) or is_nil(value) do
      :ok
    else
      raise ArgumentError,
            "The '#{Atom.to_string(field)}' field must be a #{inspect(struct_module)} struct or nil"
    end
  end

  @spec task(term()) :: :ok
  def task(%Task{}) do
    :ok
  end

  def task(nil) do
    raise ArgumentError, "The 'task' field is required"
  end

  def task(value) do
    raise ArgumentError,
          "The 'task' field must be a OzMcp.Structs.Task struct, got: #{inspect(value)}"
  end

  @block_modules %{
    "text" => TextContent,
    :text => TextContent,
    "image" => ImageContent,
    :image => ImageContent,
    "audio" => AudioContent,
    :audio => AudioContent,
    "resource_link" => ResourceLink,
    :resource_link => ResourceLink,
    "resource" => EmbeddedResource,
    :resource => EmbeddedResource
  }

  @spec content(ContentBlock.t()) :: :ok
  def content(%TextContent{}), do: :ok
  def content(%ImageContent{}), do: :ok
  def content(%AudioContent{}), do: :ok
  def content(%ResourceLink{}), do: :ok
  def content(%EmbeddedResource{}), do: :ok

  def content(%{} = block) do
    case block_type(block) do
      type when is_binary(type) and type != "" -> check_map_of(type, block)
      type when is_atom(type) and type not in [nil, true, false] -> check_map_of(type, block)
      _other -> raise ArgumentError, "a content block map needs a 'type', got: #{inspect(block)}"
    end
  end

  def content(value) do
    raise ArgumentError,
          "The 'content' field is required and must be one of " <>
            "TextContent, ImageContent, AudioContent, ResourceLink " <>
            "EmbeddedResource structs or a map with a 'type', got: #{inspect(value)}"
  end

  defp block_type(block) do
    case Map.fetch(block, "type") do
      {:ok, type} -> type
      :error -> Map.get(block, :type)
    end
  end

  # One check of a map block: the field rules of its module, without the
  # wire map. An unknown type keeps the rule of the old shape check.
  #
  defp check_map_of(type, block) do
    case @block_modules do
      %{^type => module} -> module.check_map(block)
      _other -> :ok
    end
  end

  # The name of an item is the index of a read item, or the string of an embedded resource.
  #
  @doc false
  @spec resource_contents(map(), String.t() | non_neg_integer()) :: :ok
  def resource_contents(%{} = item, name) do
    cond do
      Map.has_key?(item, "text") or Map.has_key?(item, :text) ->
        TextResourceContents.check_map(item)

      Map.has_key?(item, "blob") or Map.has_key?(item, :blob) ->
        BlobResourceContents.check_map(item)

      true ->
        raise ArgumentError, "#{item_name(name)} needs a 'text' or a 'blob'"
    end
  end

  defp item_name(name) when is_binary(name), do: name
  defp item_name(index) when is_integer(index), do: "contents[#{index}]"

  # One read of the three members: a second key split here doubled the cost of a block check.
  #
  @doc false
  @spec annotations(term()) :: :ok
  def annotations(nil), do: :ok
  def annotations(%Annotations{} = annotations), do: Annotations.check(annotations)

  def annotations(%{__struct__: other}) do
    raise(
      ArgumentError,
      "annotations must be a OzMcp.Structs.Annotations, got: #{inspect(other)}"
    )
  end

  def annotations(%{} = annotations) do
    Annotations.check(
      Keys.get(annotations, "audience", :audience, nil),
      Keys.get(annotations, "priority", :priority, nil),
      Keys.get(annotations, "lastModified", :lastModified, nil)
    )
  end

  def annotations(value) do
    raise(
      ArgumentError,
      "annotations must be a map or a OzMcp.Structs.Annotations, got: #{inspect(value)}"
    )
  end

  @doc false
  @spec icons(term()) :: :ok
  def icons(nil), do: :ok

  def icons(icons) do
    case Nested.icons(icons) do
      {:ok, converted} -> Enum.each(converted, &Icon.check/1)
      {:error, message} -> raise ArgumentError, message
    end
  end

  @max_completion_values 100

  @doc false
  @spec completion_values(term()) :: :ok
  def completion_values(values) when is_list(values) do
    if length(values) > @max_completion_values do
      raise ArgumentError,
            "The 'values' field must contain at most #{@max_completion_values} items"
    end

    Enum.each(values, fn
      value when is_binary(value) ->
        :ok

      value ->
        raise ArgumentError,
              "The 'values' field must be a list of strings, got: #{inspect(value)}"
    end)
  end

  def completion_values(_values) do
    raise ArgumentError, "The 'values' field must be a list"
  end
end
