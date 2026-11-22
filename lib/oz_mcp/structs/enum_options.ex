defmodule OzMcp.Structs.EnumOptions do
  @moduledoc """
  Helper module shared by `OzMcp.Structs.EnumSchema` and
  `OzMcp.Structs.MultiSelectEnumSchema`.

  An option is a string (`"red"`), a `{value, title}` tuple, or a map with
  the keys `:const` / `"const"` and `:title` / `"title"`. A list where no
  option has a title is rendered as `enum`; as soon as one option has a
  title, the list is rendered as `{const, title}` pairs (a missing title
  defaults to the value).
  """

  @type option :: String.t() | {String.t(), String.t()} | map()

  @doc """
  Normalizes the options to a list of `{value, title | nil}`. Raises
  `ArgumentError` when the list is empty, an option is invalid, or a value
  is repeated.
  """
  @spec normalize(term()) :: [{String.t(), String.t() | nil}]
  def normalize([_ | _] = options) do
    normalized = Enum.map(options, &option/1)
    values = Enum.map(normalized, &elem(&1, 0))

    if length(values) != length(Enum.uniq(values)) do
      raise ArgumentError, "The 'options' field cannot repeat a value"
    end

    normalized
  end

  def normalize(_other) do
    raise ArgumentError, "The 'options' field is required and must be a non-empty list"
  end

  @doc """
  The values of normalized options.
  """
  @spec values([{String.t(), String.t() | nil}]) :: [String.t()]
  def values(options), do: Enum.map(options, &elem(&1, 0))

  @doc """
  Renders normalized options: `{:enum, values}` or `{:titled, [%{const:, title:}]}`.
  """
  @spec render([{String.t(), String.t() | nil}]) ::
          {:enum, [String.t()]} | {:titled, [map()]}
  def render(options) do
    if Enum.all?(options, fn {_value, title} -> is_nil(title) end) do
      {:enum, values(options)}
    else
      {:titled,
       Enum.map(options, fn {value, title} -> %{const: value, title: title || value} end)}
    end
  end

  defp option(value) when is_binary(value) and value != "", do: {value, nil}

  defp option({value, title}) when is_binary(value) and value != "" and is_binary(title),
    do: {value, title}

  defp option(%{} = map) do
    value = Map.get(map, :const) || Map.get(map, "const")
    title = Map.get(map, :title) || Map.get(map, "title")

    if is_binary(value) and value != "" and (is_nil(title) or is_binary(title)) do
      {value, title}
    else
      invalid(map)
    end
  end

  defp option(other), do: invalid(other)

  defp invalid(option) do
    raise ArgumentError,
          "invalid option, expected a string, a {value, title} tuple or a map with " <>
            "'const' and 'title', got: #{inspect(option)}"
  end
end
