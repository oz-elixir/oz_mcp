#
# The nested values of an entity map become their structs before the
# build check of the normalizer and the icons of a result block use
# the same walk. An unknown nested key is an error for an entity and
# dropped for a result block: the old shape check accepted it.
#
defmodule OzMcp.Structs.Nested do
  @moduledoc false

  alias OzMcp.Structs.{Annotations, Icon, Keys, PromptArgument, ToolAnnotations, ToolExecution}

  @spec_map Map.new(
              [Annotations, Icon, PromptArgument, ToolAnnotations, ToolExecution],
              fn module ->
                {module, Keys.spec(Map.keys(module.__struct__()) -- [:__struct__])}
              end
            )

  @spec convert(term(), term(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def convert(spec, value, path), do: walk(spec, value, path, false)

  @spec icons(term()) :: {:ok, term()} | {:error, String.t()}
  def icons(icons), do: walk({:list_of, Icon}, icons, "icons", true)

  defp walk(_spec, nil, _path, _drop), do: {:ok, nil}

  defp walk({:struct, module}, value, path, drop), do: one(module, value, path, drop)

  defp walk({:list_of, module}, list, path, drop) when is_list(list),
    do: items(module, list, path, drop)

  defp walk({:list_of, _module}, _value, path, _drop),
    do: {:error, "#{path} must be a list"}

  defp walk(_spec, value, _path, _drop), do: {:ok, value}

  defp one(module, %module{} = struct, _path, _drop), do: {:ok, struct}

  defp one(module, %{__struct__: other}, path, _drop),
    do: {:error, "#{path} must be a #{inspect(module)}, got: #{inspect(other)}"}

  defp one(module, map, path, drop) when is_map(map) do
    spec = Map.fetch!(@spec_map, module)

    if drop do
      {:ok, struct(module, Keys.known(map, spec))}
    else
      {known, unknown} = Keys.split(map, spec)

      if map_size(unknown) == 0 do
        {:ok, struct(module, known)}
      else
        [key | _] = Map.keys(unknown)
        {:error, "#{path}.#{key} is not a field of #{inspect(module)}"}
      end
    end
  end

  defp one(module, value, path, _drop),
    do: {:error, "#{path} must be a map or a #{inspect(module)}, got: #{inspect(value)}"}

  defp items(module, list, path, drop) do
    if proper_list?(list) do
      list
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
        case one(module, value, "#{path}[#{index}]", drop) do
          {:ok, item} -> {:cont, {:ok, [item | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, items} -> {:ok, Enum.reverse(items)}
        error -> error
      end
    else
      {:error, "#{path} must be a list"}
    end
  end

  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?([]), do: true
  defp proper_list?(_), do: false
end
