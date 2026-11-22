#
# The helpers that the pipeline steps share: the reference of a
# completion request, a read of a nested key, the tasks capability of
# the server, the task support of a tool and the JSON name of a
# value.
#
defmodule OzMcp.Pipeline.Helpers do
  @moduledoc false

  @spec completion_ref(map()) ::
          {:ok, {:prompt | :resource, String.t()}} | {:error, :rpc_invalid_ref}
  def completion_ref(%{"ref" => %{"type" => "ref/prompt", "name" => name}})
      when is_binary(name) and byte_size(name) > 0,
      do: {:ok, {:prompt, name}}

  def completion_ref(%{"ref" => %{"type" => "ref/resource", "uri" => uri}})
      when is_binary(uri) and byte_size(uri) > 0,
      do: {:ok, {:resource, uri}}

  def completion_ref(_rpc_params), do: {:error, :rpc_invalid_ref}

  @spec tasks_capability_of(map() | nil) :: map() | nil
  def tasks_capability_of(nil), do: nil

  def tasks_capability_of(capabilities) do
    Map.get(capabilities, :tasks) || Map.get(capabilities, "tasks")
  end

  @doc false
  @spec task_support_of(struct() | nil) :: :forbidden | :optional | :required
  def task_support_of(%{execution: %{taskSupport: support}}) when support != nil, do: support
  def task_support_of(_tool), do: :forbidden

  @doc false
  @spec tools_call_task_capable?(map() | nil) :: boolean()
  def tools_call_task_capable?(nil), do: false
  def tools_call_task_capable?(tasks), do: deep(tasks, [:requests, :tools, :call]) != nil

  @spec deep(term(), [String.t() | atom()]) :: term()
  def deep(nil, _path), do: nil

  def deep(map, []), do: map

  def deep(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> deep(value, rest)
      :error -> deep(Map.get(map, to_string(key)), rest)
    end
  end

  def deep(_other, _path), do: nil

  @spec type_name(term()) :: String.t()
  def type_name(value) when is_binary(value), do: "string"
  def type_name(value) when is_integer(value), do: "integer"
  def type_name(value) when is_float(value), do: "float"
  def type_name(value) when is_boolean(value), do: "boolean"
  def type_name(value) when is_list(value), do: "array"
  def type_name(value) when is_map(value), do: "object"

  def type_name(_), do: "unknown"
end
