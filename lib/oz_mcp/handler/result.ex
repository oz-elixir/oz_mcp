#
# Builds the result map of a user callback into its result struct, so a
# map and a struct get the same build/1 check. Called by Invoke.normalize/2.
#
defmodule OzMcp.Handler.Result do
  @moduledoc false

  alias OzMcp.Structs.{
    Builder,
    CallToolResult,
    CompleteResult,
    GetPromptResult,
    Keys,
    ReadResourceResult
  }

  @structs %{
    "tools/call" => CallToolResult,
    "resources/read" => ReadResourceResult,
    "prompts/get" => GetPromptResult,
    "completion/complete" => CompleteResult
  }

  @required %{
    "tools/call" => :content,
    "resources/read" => :contents,
    "prompts/get" => :messages,
    "completion/complete" => :completion
  }

  @methods Map.keys(@structs)

  # The module, the required member and the key spec of each method,
  # made one time at compile time. The field `extras` is not a wire
  # member: a map key "extras" is not the field.
  #
  @configs Map.new(@structs, fn {method, module} ->
             fields =
               module.__struct__()
               |> Map.keys()
               |> List.delete(:__struct__)
               |> List.delete(:extras)

             {method, {module, @required[method], Keys.spec(fields)}}
           end)

  @spec methods() :: [String.t()]
  def methods, do: @methods

  @spec normalize(String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def normalize(method, map) do
    {module, required, spec} = Map.fetch!(@configs, method)
    {known, unknown} = Keys.split(map, spec)
    unknown = drop_shadowed(unknown, map)

    with :ok <- check_required(required, known),
         :ok <- no_nil(known) do
      built = module.build(struct(module, known))
      {:ok, Builder.merge_extras(built, unknown, spec.fields)}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  # An atom key whose string form is also a key is dropped.
  #
  defp drop_shadowed(unknown, _map) when unknown == %{}, do: unknown

  defp drop_shadowed(unknown, map) do
    Map.reject(unknown, fn {key, _value} ->
      is_atom(key) and Map.has_key?(map, Atom.to_string(key))
    end)
  end

  defp check_required(field, known) do
    if Map.has_key?(known, field),
      do: :ok,
      else: {:error, "#{field} is missing"}
  end

  defp no_nil(known) do
    case Enum.find(known, fn {_field, value} -> is_nil(value) end) do
      nil -> :ok
      {field, nil} -> {:error, "#{field} must not be nil"}
    end
  end
end
