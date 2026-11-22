#
# One shape for each entity kind, checked one time with build/1.
#
defmodule OzMcp.Catalog.Normalize do
  @moduledoc false

  alias OzMcp.Auth.Scopes
  alias OzMcp.Wire

  alias OzMcp.Structs.{
    Annotations,
    Icon,
    Keys,
    Nested,
    Prompt,
    PromptArgument,
    Resource,
    ResourceTemplate,
    Tool,
    ToolAnnotations,
    ToolExecution
  }

  @modules %{
    tools: Tool,
    prompts: Prompt,
    resources: Resource,
    templates: ResourceTemplate
  }

  @nested %{
    Tool => [
      icons: {:list_of, Icon},
      execution: {:struct, ToolExecution},
      annotations: {:struct, ToolAnnotations}
    ],
    Prompt => [
      arguments: {:list_of, PromptArgument},
      icons: {:list_of, Icon}
    ],
    Resource => [
      icons: {:list_of, Icon},
      annotations: {:struct, Annotations}
    ],
    ResourceTemplate => [
      icons: {:list_of, Icon},
      annotations: {:struct, Annotations}
    ]
  }

  @specs Map.new(@modules, fn {_kind, module} ->
           {module, Keys.spec(Map.keys(module.__struct__()) -- [:__struct__])}
         end)

  @spec entity(atom(), struct() | map()) :: {:ok, struct()} | {:error, String.t()}
  def entity(kind, value) do
    case entity_and_wire(kind, value) do
      {:ok, struct, _wire} -> {:ok, struct}
      {:error, _} = error -> error
    end
  end

  @spec entity_and_wire(atom(), struct() | map()) ::
          {:ok, struct(), map()} | {:error, String.t()}
  def entity_and_wire(kind, value) do
    module = Map.fetch!(@modules, kind)

    with {:ok, struct} <- to_struct(module, value),
         {:ok, struct} <- nested(module, struct),
         wire = module.build(struct),
         :ok <- json(wire) do
      {:ok, struct, wire}
    end
  rescue
    error in [ArgumentError, RuntimeError] -> {:error, Exception.message(error)}
  end

  # The wire map goes to the client at each list: a term that is not JSON
  # stops the boot here, not each list request with the error -32603.
  #
  defp json(wire) do
    case Wire.check(wire) do
      :ok ->
        :ok

      {:error, path, reason} ->
        {:error, "the entry is not JSON at #{Wire.format_path(path)}: #{Wire.describe(reason)}"}
    end
  end

  defp to_struct(module, %module{} = struct), do: {:ok, struct_scopes(struct)}

  defp to_struct(module, %{__struct__: other}),
    do: {:error, "cannot convert a #{inspect(other)} to a #{inspect(module)}"}

  defp to_struct(module, map) when is_map(map) do
    {known, unknown} = Keys.split(map, Map.fetch!(@specs, module))
    known = known |> check_scopes() |> put_extras(unknown)
    {:ok, struct(module, known)}
  end

  defp to_struct(module, value),
    do: {:error, "cannot convert #{inspect(value)} to a #{inspect(module)}"}

  defp nested(module, struct) do
    @nested
    |> Map.get(module, [])
    |> Enum.reduce_while({:ok, struct}, fn {field, spec}, {:ok, acc} ->
      case Nested.convert(spec, Map.fetch!(acc, field), Atom.to_string(field)) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, post(value))}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp post(%ToolExecution{} = struct),
    do: %{struct | taskSupport: task_support(struct.taskSupport)}

  defp post(value), do: value

  defp task_support(value) when value in [:forbidden, :optional, :required], do: value
  defp task_support("forbidden"), do: :forbidden
  defp task_support("optional"), do: :optional
  defp task_support("required"), do: :required
  defp task_support(value), do: value

  defp check_scopes(known) do
    case Map.fetch(known, :required_scopes) do
      {:ok, scopes} -> Map.put(known, :required_scopes, Scopes.check!(scopes))
      :error -> known
    end
  end

  defp struct_scopes(%{required_scopes: nil} = struct), do: struct
  defp struct_scopes(%{required_scopes: []} = struct), do: struct

  defp struct_scopes(%{required_scopes: scopes} = struct),
    do: %{struct | required_scopes: Scopes.check!(scopes)}

  defp put_extras(known, unknown) when map_size(unknown) == 0, do: known

  defp put_extras(known, unknown) do
    case Map.get(known, :extras) do
      nil -> Map.put(known, :extras, unknown)
      extras when is_map(extras) -> Map.put(known, :extras, Map.merge(extras, unknown))
      _bad -> known
    end
  end
end
