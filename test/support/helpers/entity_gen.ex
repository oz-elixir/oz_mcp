#
# A generator of a valid entity of each kind and the writer of the
# three forms of one entity: the struct, an atom-key map and a
# string-key map.
#
# The writer changes the keys of the entity and of its nested entity
# values only. An opaque value (a schema, _meta) keeps its keys and
# the value of taskSupport becomes the string that a map carries.
#
defmodule Support.Helpers.EntityGen do
  import StreamData

  alias OzMcp.Structs.{
    Annotations,
    Icon,
    Prompt,
    PromptArgument,
    Resource,
    ResourceTemplate,
    Tool,
    ToolAnnotations,
    ToolExecution
  }

  @task_support [:forbidden, :optional, :required]

  @plain_schema %{type: "object"}
  @text_schema %{
    type: "object",
    properties: %{"text" => %{type: "string"}},
    required: ["text"]
  }

  @spec tool() :: StreamData.t(Tool.t())
  def tool do
    %{
      name: name(),
      title: text(),
      description: text(),
      inputSchema: member_of([@plain_schema, @text_schema]),
      outputSchema: constant(@plain_schema),
      _meta: constant(%{"vendor" => "gen"}),
      icons: list_of(icon(), max_length: 2),
      execution: execution(),
      annotations: tool_annotations()
    }
    |> optional_map([
      :title,
      :description,
      :outputSchema,
      :_meta,
      :icons,
      :execution,
      :annotations
    ])
    |> map(&struct(Tool, &1))
  end

  @spec prompt() :: StreamData.t(Prompt.t())
  def prompt do
    %{
      name: name(),
      title: text(),
      description: text(),
      arguments: list_of(argument(), max_length: 2),
      _meta: constant(%{"vendor" => "gen"}),
      icons: list_of(icon(), max_length: 2)
    }
    |> optional_map([:title, :description, :arguments, :_meta, :icons])
    |> map(&struct(Prompt, &1))
  end

  @spec resource() :: StreamData.t(Resource.t())
  def resource do
    %{
      uri: map(name(), &"file:///gen/#{&1}.md"),
      name: name(),
      title: text(),
      description: text(),
      mimeType: constant("text/markdown"),
      _meta: constant(%{"vendor" => "gen"}),
      icons: list_of(icon(), max_length: 2),
      annotations: annotations(),
      size: member_of([0, 64, 4096])
    }
    |> optional_map([:title, :description, :mimeType, :_meta, :icons, :annotations, :size])
    |> map(&struct(Resource, &1))
  end

  @spec template() :: StreamData.t(ResourceTemplate.t())
  def template do
    %{
      uriTemplate: member_of(["file:///docs/{path}", "file:///{+path}"]),
      name: name(),
      title: text(),
      description: text(),
      mimeType: constant("text/markdown"),
      _meta: constant(%{"vendor" => "gen"}),
      icons: list_of(icon(), max_length: 2),
      annotations: annotations()
    }
    |> optional_map([:title, :description, :mimeType, :_meta, :icons, :annotations])
    |> map(&struct(ResourceTemplate, &1))
  end

  @spec forms(struct()) :: [struct() | map()]
  def forms(entity), do: [entity, atom_map(entity), string_map(entity)]

  @spec atom_map(struct()) :: map()
  def atom_map(entity), do: members(entity, :atom)

  @spec string_map(struct()) :: map()
  def string_map(entity), do: members(entity, :string)

  # ------------------------------------------------------------------
  # The values of the members
  # ------------------------------------------------------------------

  defp name, do: string(:alphanumeric, min_length: 1, max_length: 12)
  defp text, do: string(:alphanumeric, min_length: 1, max_length: 24)

  defp icon do
    %{
      src: constant("https://example.com/icon.png"),
      mimeType: constant("image/png"),
      sizes: constant(["16x16"]),
      theme: member_of([:light, :dark])
    }
    |> optional_map([:mimeType, :sizes, :theme])
    |> map(&struct(Icon, &1))
  end

  defp argument do
    %{
      name: name(),
      title: text(),
      description: text(),
      required: boolean()
    }
    |> optional_map([:title, :description, :required])
    |> map(&struct(PromptArgument, &1))
  end

  defp execution do
    %{
      taskSupport: member_of(@task_support),
      poll_interval: member_of([100, 5_000]),
      immediate_response: constant("working")
    }
    |> optional_map([:poll_interval, :immediate_response])
    |> map(&struct(ToolExecution, &1))
  end

  defp tool_annotations do
    %{
      title: text(),
      readOnlyHint: boolean(),
      destructiveHint: boolean(),
      idempotentHint: boolean(),
      openWorldHint: boolean()
    }
    |> optional_map()
    |> map(&struct(ToolAnnotations, &1))
  end

  # One field of the annotations is always set: the build refuses an
  # annotations whose fields are all nil.
  #
  defp annotations do
    %{
      audience: constant(["user", "assistant"]),
      priority: member_of([0.0, 0.5, 1.0]),
      lastModified: constant("2025-01-12T15:00:58Z")
    }
    |> optional_map()
    |> map(&annotation/1)
  end

  defp annotation(values) do
    value = struct(Annotations, values)

    if value.audience == nil and value.priority == nil and value.lastModified == nil do
      %Annotations{priority: 0.5}
    else
      value
    end
  end

  # ------------------------------------------------------------------
  # The forms of one entity
  # ------------------------------------------------------------------

  # A map omits a member whose value is nil and omits the empty scopes
  # that the struct carries as its default: a map that carries
  # required_scopes: [] is an error.
  #
  defp member?({_key, nil}), do: false
  defp member?({:required_scopes, []}), do: false
  defp member?(_pair), do: true

  defp members(struct, mode) when is_struct(struct) do
    map =
      struct
      |> Map.from_struct()
      |> Enum.filter(&member?/1)
      |> Map.new(fn {key, value} -> {key_name(key, mode), value_of(value, mode)} end)

    post(struct, map, mode)
  end

  defp key_name(key, :atom), do: key
  defp key_name(key, :string), do: Atom.to_string(key)

  defp value_of(list, mode) when is_list(list), do: Enum.map(list, &value_of(&1, mode))
  defp value_of(value, mode) when is_struct(value), do: members(value, mode)
  defp value_of(value, _mode), do: value

  # A map carries taskSupport as the string form of the value of the
  # struct, in both map forms.
  #
  defp post(%ToolExecution{}, map, mode) do
    key = key_name(:taskSupport, mode)

    if Map.has_key?(map, key),
      do: Map.put(map, key, to_string(Map.fetch!(map, key))),
      else: map
  end

  defp post(_struct, map, _mode), do: map
end
