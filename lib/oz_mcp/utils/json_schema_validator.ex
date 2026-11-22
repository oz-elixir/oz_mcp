#
# JSON Schema validation. A root is built from a schema when it is
# needed; nothing is cached.
#
defmodule OzMcp.Utils.JsonSchemaValidator do
  @moduledoc false

  alias JSV.ErrorFormatter
  alias JSV.Root
  alias JSV.ValidationError

  @type error :: String.t()

  # Checks the schema at compile time and raises `ArgumentError` when it is
  # invalid. `context` appears in the message.
  #
  @spec check_validate!(term(), map()) :: :ok
  def check_validate!(context, schema) do
    case build(schema) do
      {:ok, _root} ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "invalid schema for key #{inspect(context)}: #{Exception.message(reason)}"
    end
  end

  # Builds the root of `schema`. Nothing is cached and nothing is logged.
  #
  @spec compile(map() | nil) :: {:ok, Root.t()} | {:error, term()}
  def compile(schema), do: build(schema)

  # Validates `data` against `root`. With `apply_defaults: true`, the absent
  # properties that declare a default are filled in first.
  #
  @spec validate(Root.t(), map() | nil, keyword()) :: {:ok, map()} | {:error, [error()]}
  def validate(root, data, opts \\ [])

  def validate(%Root{} = root, data, opts) when is_list(opts) do
    data = data || %{}

    data =
      if Keyword.get(opts, :apply_defaults, false) do
        apply_defaults(root.raw, data)
      else
        data
      end

    case JSV.validate(data, root) do
      {:ok, _validated} ->
        {:ok, data}

      {:error, error} ->
        {:error, messages(error)}
    end
  end

  # Validates `data` against `schema` without caching it. For a schema that
  # is used once.
  #
  @spec validate_schema(map(), term()) :: {:ok, term()} | {:error, [error()] | :invalid_schema}
  def validate_schema(schema, data) do
    case build(schema) do
      {:ok, root} -> validate(root, data)
      {:error, _reason} -> {:error, :invalid_schema}
    end
  end

  defp build(schema) do
    JSV.build(normalize(schema), formats: true)
  end

  defp apply_defaults(schema, nil), do: apply_defaults(schema, %{})

  defp apply_defaults(schema, arguments) when is_map(arguments) do
    Enum.reduce(properties_of(schema), arguments, fn {name, prop_schema}, acc ->
      if Map.has_key?(acc, name) do
        acc
      else
        case fetch(prop_schema, "default") do
          {:ok, default} -> Map.put(acc, name, default)
          :error -> acc
        end
      end
    end)
  end

  defp apply_defaults(_schema, arguments), do: arguments

  defp normalize(schema) when is_map(schema), do: stringify_keys(schema)
  defp normalize(_schema), do: %{}

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp properties_of(schema) do
    case fetch(schema, "properties") do
      {:ok, properties} when is_map(properties) ->
        Map.new(properties, fn {k, v} -> {to_string(k), v} end)

      _ ->
        %{}
    end
  end

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp fetch(_value, _key), do: :error

  defp messages(%ValidationError{} = error) do
    %{details: details} =
      JSV.normalize_error(error, min_error_level: ErrorFormatter.level_cause())

    Enum.flat_map(details, fn unit ->
      Enum.map(unit[:errors] || [], fn e ->
        location_prefix(error_location(e, unit[:instanceLocation])) <> e.message
      end)
    end)
  end

  # The error of a `false` subschema sits on the rejected key and its
  # message names that key: the prefix names the parent, as before
  # jsv 0.28.
  #
  defp error_location(%{kind: :boolean_schema}, "#/" <> path) do
    case path |> String.split("/") |> Enum.drop(-1) do
      [] -> "#"
      segments -> "#/" <> Enum.join(segments, "/")
    end
  end

  defp error_location(_error, location), do: location

  defp location_prefix("#"), do: ""
  defp location_prefix(nil), do: ""

  defp location_prefix("#/" <> path) do
    field =
      path
      |> String.split("/")
      |> Enum.map_join(".", &unescape_json_pointer/1)

    "'#{field}' "
  end

  defp location_prefix(_location), do: ""

  defp unescape_json_pointer(segment) do
    segment
    |> String.replace("~1", "/")
    |> String.replace("~0", "~")
  end
end
