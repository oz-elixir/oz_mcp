#
# Full walk over the modules of a server, in the declared order, for the
# tests of OzMcp.Catalog. Each module is read from list/0.
#
defmodule Support.Helpers.CatalogWalk do
  def find_tool(server, name), do: find(server, :tools, name)

  def find_prompt(server, name), do: find(server, :prompts, name)

  def find_resource(server, uri), do: find(server, :resources, uri)

  def find_template(server, uri) do
    server
    |> modules(:templates)
    |> Enum.find_value(fn module -> match_template(module, uri) end)
  end

  def find_template_by_ref(server, uri_template) do
    server
    |> modules(:templates)
    |> Enum.find_value(fn module ->
      case Enum.find(module.list(), &(key(:templates, &1) == uri_template)) do
        nil -> nil
        template -> {module, normalize(:templates, template), %{}}
      end
    end)
  end

  defp match_template(module, uri) do
    Enum.find_value(module.list(), fn template ->
      compiled = OzMcp.Utils.TemplateUri.compile!(key(:templates, template))

      case OzMcp.Utils.TemplateUri.match_compiled(compiled, uri) do
        {:ok, _uri_template, params} -> {module, normalize(:templates, template), params}
        nil -> nil
      end
    end)
  end

  def find(server, kind, key) do
    server
    |> modules(kind)
    |> Enum.find_value(fn module ->
      case entity(module, kind, key) do
        nil -> nil
        entity -> {module, entity}
      end
    end)
  end

  defp entity(module, kind, key) do
    case Enum.find(module.list(), &(key(kind, &1) == key)) do
      nil -> nil
      raw -> normalize(kind, raw)
    end
  end

  defp normalize(kind, raw) do
    {:ok, struct} = OzMcp.Catalog.Normalize.entity(kind, raw)
    struct
  end

  defp key(:resources, entity), do: field(entity, :uri)
  defp key(:templates, entity), do: field(entity, :uriTemplate)
  defp key(_named, entity), do: field(entity, :name)

  defp field(entity, name), do: Map.get(entity, name) || Map.get(entity, Atom.to_string(name))

  defp modules(server, kind) do
    case Map.get(server.config(), kind) do
      %{modules: modules} -> modules
      _none -> []
    end
  end
end
