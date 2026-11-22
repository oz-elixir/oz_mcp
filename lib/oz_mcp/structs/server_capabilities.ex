defmodule OzMcp.Structs.ServerCapabilities do
  @moduledoc """
  Helper module used to build `ServerCapabilities` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %ServerCapabilities{}
    |> ServerCapabilities.resources(true)
    |> ServerCapabilities.build()
  ```

  Result:

  ```elixir
  %{resources: %{subscribe: true}}
  ```

  ## Long example:

  ```elixir
  %ServerCapabilities{}
    |> ServerCapabilities.logging(%{})
    |> ServerCapabilities.completions(%{})
    |> ServerCapabilities.resources(true)
    |> ServerCapabilities.tasks(%{}, %{}, %{tools: %{call: %{}}})
    |> ServerCapabilities.build()
  ```

  Result:

  ```elixir
  %{
    resources: %{subscribe: true},
    tasks: %{list: %{}, cancel: %{}, requests: %{tools: %{call: %{}}}},
    logging: %{},
    completions: %{}
  }
  ```

  Specification: [ServerCapabilities](https://modelcontextprotocol.io/specification/2025-11-25/schema#servercapabilities)
  """

  use OzMcp.Structs.Wire,
    fields: [
      experimental: :map,
      logging: :map,
      completions: :map,
      prompts: {:map, setter: false},
      resources: {:map, setter: false},
      tools: {:map, setter: false},
      tasks: {:map, setter: false}
    ]

  @spec resources(t(), boolean() | nil) :: t()
  def resources(struct, subscribe) do
    case maybe_put_boolean(%{}, :subscribe, subscribe) do
      value when map_size(value) == 0 -> struct
      value -> Map.put(struct, :resources, value)
    end
  end

  @spec tasks(t(), map() | nil, map() | nil, map() | nil) :: t()
  def tasks(struct, nil, nil, nil), do: struct

  def tasks(struct, list, cancel, requests) do
    value =
      %{}
      |> maybe_put_object(:list, list)
      |> maybe_put_object(:cancel, cancel)
      |> maybe_put_object(:requests, requests)

    if Kernel.map_size(value) == 0 do
      struct
    else
      Map.put(struct, :tasks, value)
    end
  end

  defp maybe_put_boolean(struct, _key, nil), do: struct

  defp maybe_put_boolean(struct, _key, false), do: struct

  defp maybe_put_boolean(struct, key, value) do
    Map.put(struct, key, value)
  end

  defp maybe_put_object(map, _key, nil), do: map

  defp maybe_put_object(_map, _key, value) when not is_map(value) do
    raise ArgumentError, "tasks capability values must be maps, got: #{inspect(value)}"
  end

  defp maybe_put_object(map, key, value), do: Map.put(map, key, value)
end
