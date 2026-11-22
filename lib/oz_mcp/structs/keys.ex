#
# The key split of a wire map: the string key wins over the atom key of
# the same field and no string becomes an atom. The spec comes from spec/1.
#
defmodule OzMcp.Structs.Keys do
  @moduledoc false

  @typedoc false
  @type spec :: %{
          fields: [atom()],
          names: %{String.t() => atom()}
        }

  @spec spec([atom()]) :: spec()
  def spec(fields) do
    %{
      fields: fields,
      names: Map.new(fields, &{Atom.to_string(&1), &1})
    }
  end

  # One read of a member of a raw map: the string key wins and no atom
  # is made. The check of a block reads each member with it.
  #
  @compile {:inline, get: 4}

  @spec get(map(), String.t(), atom(), term()) :: term()
  def get(map, name, field, default) do
    case map do
      %{^name => value} -> value
      %{^field => value} -> value
      _other -> default
    end
  end

  # The split walks the map, not the spec: a result map holds a few keys and a
  # spec holds all fields of the struct. An atom key never overwrites a string.
  #
  @spec split(map(), spec()) :: {map(), map()}
  def split(map, %{fields: fields, names: names}) do
    Enum.reduce(map, {%{}, %{}}, fn {key, value}, {known, unknown} ->
      case field_of(key, fields, names) do
        nil ->
          {known, Map.put(unknown, key, value)}

        field ->
          if is_atom(key) and Map.has_key?(known, field) do
            {known, unknown}
          else
            {Map.put(known, field, value), unknown}
          end
      end
    end)
  end

  @spec known(map(), spec()) :: map()
  def known(map, %{fields: fields, names: names}) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      case field_of(key, fields, names) do
        nil ->
          acc

        field ->
          if is_atom(key) and Map.has_key?(acc, field) do
            acc
          else
            Map.put(acc, field, value)
          end
      end
    end)
  end

  defp field_of(key, fields, _names) when is_atom(key), do: if(key in fields, do: key)
  defp field_of(key, _fields, names) when is_binary(key), do: Map.get(names, key)
  defp field_of(_key, _fields, _names), do: nil
end
