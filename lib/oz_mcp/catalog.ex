#
# The entities of a server, ready for the lookups of a request. The
# configuration check (`OzMcp.Instance.Config`) and the readers of a
# request call it.
#
# Each module is read one time, at the boot of the instance: a DSL
# module gives __catalog__/0 and a module with dsl?: false gives
# list/0. Each kind holds one list, in the declared order of the
# modules and a page is a slice of that list. A lookup and a list read
# the stored catalog only and no request calls the code of the
# application to find or list an entity.
#
# Hazard: a bad entity stops the boot.
#
defmodule OzMcp.Catalog do
  @moduledoc false

  alias OzMcp.Catalog.{Entry, Normalize}
  alias OzMcp.Utils.{JsonSchemaValidator, TemplateUri}
  alias OzMcp.Wire

  defstruct tools: %{},
            prompts: %{},
            resources: %{},
            templates: [],
            templates_by_ref: %{},
            roots: %{},
            scopes: %{},
            ordered: %{},
            encoded: %{}

  @type t :: %__MODULE__{}

  @kinds [:tools, :prompts, :resources, :templates]

  @spec build!(module()) :: t()
  def build!(server) do
    config = server.config()
    reads = Map.new(@kinds, fn kind -> {kind, groups(config, kind)} end)

    tools = index(reads.tools)
    prompts = index(reads.prompts)
    resources = index(reads.resources)
    templates_by_ref = index(reads.templates)
    ordered = Map.new(reads, fn {kind, groups} -> {kind, ordered_list(groups)} end)

    %__MODULE__{
      tools: tools,
      prompts: prompts,
      resources: resources,
      templates: flat_templates(reads.templates),
      templates_by_ref: templates_by_ref,
      roots: roots(tools),
      scopes:
        scopes(tools: tools, prompts: prompts, resources: resources, templates: templates_by_ref),
      ordered: ordered,
      encoded: encoded(ordered)
    }
  end

  # The one list of a kind, in the declared order of the modules: the
  # pairs, the wire maps and their count are made one time at boot.
  #
  defp ordered_list(groups) do
    entries = Enum.flat_map(groups, fn {_module, entries} -> entries end)
    pairs = Enum.map(entries, &{&1.entity, &1.wire})
    %{pairs: pairs, wires: Enum.map(entries, & &1.wire), count: length(entries)}
  end

  # The inside of the JSON array of the wire maps of a kind, encoded one
  # time at boot: the plain answer of a list writes it as it is, with the
  # answer encoder of Wire. A kind with no entry, or whose encode fails,
  # has no binary and its list sends the stored wire maps.
  #
  defp encoded(ordered) do
    ordered
    |> Map.new(fn {kind, %{wires: wires}} -> {kind, encoded_list(wires)} end)
    |> Map.reject(fn {_kind, bytes} -> is_nil(bytes) end)
  end

  defp encoded_list([]), do: nil

  defp encoded_list(wires) do
    case Wire.encode(wires) do
      {:ok, bytes} -> binary_part(bytes, 1, byte_size(bytes) - 2)
      {:error, _path, _reason} -> nil
    end
  end

  @doc false
  @spec ordered(t(), atom()) :: %{
          pairs: [{struct(), map()}],
          wires: [map()],
          count: non_neg_integer()
        }
  def ordered(%__MODULE__{ordered: ordered}, kind) do
    Map.get(ordered, kind, %{pairs: [], wires: [], count: 0})
  end

  @doc false
  @spec encoded(t(), atom()) :: binary() | nil
  def encoded(%__MODULE__{encoded: encoded}, kind), do: Map.get(encoded, kind)

  # The scopes of the static entities of each kind: the sorted union of
  # the field required_scopes of the structs, whatever form the module
  # gave. The metadata document and the filter of the lists read them.
  #
  defp scopes(indexes) do
    Map.new(indexes, fn {kind, index} ->
      values =
        index
        |> Map.values()
        |> Enum.flat_map(fn {_module, entry} -> entry.entity.required_scopes end)
        |> Enum.uniq()
        |> Enum.sort()

      {kind, values}
    end)
  end

  @doc false
  @spec required_scopes(t(), atom()) :: [String.t()]
  def required_scopes(%__MODULE__{scopes: scopes}, kind), do: Map.get(scopes, kind, [])

  defp modules(config, kind) do
    case Map.get(config, kind) do
      %{modules: modules} -> modules
      _none -> []
    end
  end

  @spec entries(module(), atom()) :: [Entry.t()]
  def entries(module, kind) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__catalog__, 0) do
      Enum.map(module.__catalog__(), fn entry ->
        {struct, wire} = static!(module, kind, entry.entity)
        %{entry | entity: struct, wire: wire}
      end)
    else
      Enum.map(module.list(), &entry(kind, static!(module, kind, &1)))
    end
  end

  defp entry(kind, {struct, wire}) do
    key = key(kind, struct)
    %Entry{key: key, entity: struct, wire: wire, matcher: matcher(kind, key)}
  end

  defp static!(module, kind, raw) do
    case Normalize.entity_and_wire(kind, raw) do
      {:ok, struct, wire} -> {struct, wire}
      {:error, message} -> raise ArgumentError, "#{inspect(module)}: #{kind}: #{message}"
    end
  end

  defp key(:resources, entity), do: entity.uri
  defp key(:templates, entity), do: entity.uriTemplate
  defp key(_named, entity), do: entity.name

  defp matcher(:templates, key), do: TemplateUri.compile!(key)
  defp matcher(_kind, _key), do: nil

  # The groups of a kind in the declared order: each module holds the
  # entries of its one read at boot.
  #
  defp groups(config, kind) do
    config |> modules(kind) |> Enum.map(&{&1, entries(&1, kind)})
  end

  defp index(groups) do
    for {module, entries} <- groups, entry <- entries, reduce: %{} do
      acc -> Map.put_new(acc, entry.key, {module, entry})
    end
  end

  # The templates in the declared order, with their compiled matcher.
  #
  defp flat_templates(groups) do
    Enum.flat_map(groups, fn {module, entries} ->
      Enum.map(entries, &{module, &1})
    end)
  end

  # The compiled roots of the static tools. A root that is built here is
  # never built at a request.
  #
  defp roots(tools) do
    for {module, %{entity: tool}} <- Map.values(tools),
        {kind, schema} <- schemas(tool),
        schema != nil,
        into: %{} do
      {{module, tool.name, kind}, root!(module, tool.name, kind, schema)}
    end
  end

  defp schemas(tool) do
    [input: tool.inputSchema || %{}, output: tool.outputSchema]
  end

  defp root!(module, name, kind, schema) do
    case JsonSchemaValidator.compile(schema) do
      {:ok, root} ->
        root

      {:error, reason} ->
        raise ArgumentError,
              "invalid #{kind} schema for tool #{inspect(name)} in #{inspect(module)}: " <>
                Exception.message(reason)
    end
  end

  @spec find_tool(t(), term()) :: {module(), struct()} | nil
  def find_tool(%__MODULE__{tools: tools}, name), do: found(tools, name)

  @spec find_prompt(t(), term()) :: {module(), struct()} | nil
  def find_prompt(%__MODULE__{prompts: prompts}, name), do: found(prompts, name)

  @spec find_resource(t(), term()) :: {module(), struct()} | nil
  def find_resource(%__MODULE__{resources: resources}, uri), do: found(resources, uri)

  defp found(index, key) do
    case Map.get(index, key) do
      nil -> nil
      {module, entry} -> {module, entry.entity}
    end
  end

  @spec find_template(t(), String.t()) :: {module(), struct(), map()} | nil
  def find_template(%__MODULE__{templates: ordered}, uri) do
    Enum.find_value(ordered, &match_item(&1, uri))
  end

  defp match_item({module, entry}, uri) do
    case TemplateUri.match_compiled(entry.matcher, uri) do
      {:ok, _template, params} -> {module, entry.entity, params}
      nil -> nil
    end
  end

  @spec find_template_by_ref(t(), String.t()) :: {module(), struct(), map()} | nil
  def find_template_by_ref(%__MODULE__{templates_by_ref: index}, uri_template) do
    case Map.get(index, uri_template) do
      nil -> nil
      {module, entry} -> {module, entry.entity, %{}}
    end
  end

  # ------------------------------------------------------------------
  # Boot and store
  # ------------------------------------------------------------------

  @spec boot(module()) :: t()
  def boot(server), do: store(server, build!(server))

  # A JSV root with a `pattern` holds a reference, so 2 builds of one schema
  # are not equal and a put of an equal catalog would start a global GC. The
  # roots and the lists are pure functions of the entities: the compare
  # leaves the roots out and keeps the lists.
  #
  defp store(server, catalog) do
    key = {__MODULE__, server}
    stored = :persistent_term.get(key, nil)

    if stored != nil and %{stored | roots: nil} == %{catalog | roots: nil} do
      stored
    else
      :persistent_term.put(key, catalog)
      catalog
    end
  end

  @spec fetch(module()) :: t()
  def fetch(server) do
    case :persistent_term.get({__MODULE__, server}, nil) do
      nil -> boot(server)
      catalog -> catalog
    end
  end

  # A static tool has its root in the catalog. A task record can name a
  # tool of another version of the code: its schema is compiled again,
  # with no cache.
  #
  @spec fetch_root(t(), module(), String.t(), :input | :output, map()) ::
          {:ok, JSV.Root.t()} | {:error, :invalid_schema}
  def fetch_root(%__MODULE__{roots: roots}, module, name, kind, schema) do
    case roots do
      %{{^module, ^name, ^kind} => root} ->
        {:ok, root}

      _other ->
        case JsonSchemaValidator.compile(schema) do
          {:ok, root} -> {:ok, root}
          {:error, _reason} -> {:error, :invalid_schema}
        end
    end
  end
end
