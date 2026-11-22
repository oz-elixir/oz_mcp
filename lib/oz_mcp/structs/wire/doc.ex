defmodule OzMcp.Structs.Wire.Doc do
  @moduledoc false

  @spec table([struct()]) :: String.t()
  def table(fields) do
    rows = fields |> Enum.filter(&(&1.setter || &1.emit != :never)) |> Enum.map(&row/1)

    """

    ## Fields

    | Field | Setter | Type | Required |
    |---|---|---|---|
    #{Enum.join(rows, "\n")}
    """
  end

  defp row(field) do
    required = if field.required, do: "yes", else: "no"
    setter = if field.setter, do: "`#{field.setter}/2`", else: "see the module functions"
    "| `#{field.key}` | #{setter} | #{type(field)} | #{required} |"
  end

  defp type(field) do
    text = base_type(field)
    if field.emit == :never, do: text <> ", never sent", else: text
  end

  defp base_type(%{type: type}) when type != nil, do: escape(Macro.to_string(type))
  defp base_type(%{kind: :uri, required: true, absolute: true}), do: "absolute URI"
  defp base_type(%{kind: :uri, required: true}), do: "string"
  defp base_type(%{kind: :uri}), do: "URI"
  defp base_type(%{kind: kind}), do: kind_type(kind)

  defp kind_type(:string), do: "string"
  defp kind_type(:any_string), do: "string"
  defp kind_type(:non_neg_integer), do: "non-negative integer"
  defp kind_type(:number), do: "number"
  defp kind_type({:between, min, max}), do: "number between #{min} and #{max}"
  defp kind_type(:boolean), do: "boolean"
  defp kind_type(:map), do: "map"
  defp kind_type(:meta), do: "map"
  defp kind_type(:extras), do: "map"
  defp kind_type(:list), do: "list"
  defp kind_type(:content_list), do: "list of `t:OzMcp.Structs.ContentBlock.t/0`"
  defp kind_type(:task), do: "`t:OzMcp.Structs.Task.t/0`"
  defp kind_type(:scopes), do: "list of scopes"
  defp kind_type(:any), do: "term"
  defp kind_type({:one_of, values}), do: Enum.map_join(values, ", ", &"`#{inspect(&1)}`")
  defp kind_type({:struct, module}), do: module_type(module)
  defp kind_type({:list_of, module}), do: "list of #{module_type(module)}"
  defp kind_type({:maps_of, module}), do: "list of #{module_type(module)} or map"
  defp kind_type(_kind), do: "term"

  defp module_type(module), do: "`t:#{inspect(module)}.t/0`"

  defp escape(text), do: String.replace(text, "|", "\\|")
end
