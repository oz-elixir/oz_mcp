#
# The `io.modelcontextprotocol/related-task` metadata.
#
# The MCP specification (2025-11-25, "Tasks") asks that each request,
# notification and response of a task has this key in its `_meta`, with
# the value `%{"taskId" => task_id}`. `tasks/get`, `tasks/result` and
# `tasks/cancel` carry the task id in their params, so they do not get
# it; `notifications/tasks/status` and `tasks/list` do not get it.
#
defmodule OzMcp.Tasks.RelatedTask do
  @moduledoc false

  @key "io.modelcontextprotocol/related-task"

  # The key of the metadata.
  #
  @spec key() :: String.t()
  def key, do: @key

  # The `_meta` map of a task.
  #
  @spec meta(String.t()) :: map()
  def meta(task_id) when is_binary(task_id), do: %{@key => %{"taskId" => task_id}}

  # Merges the metadata of the task into the `_meta` of `params`.
  #
  # `meta_key` is the key of `_meta` in `params`: `"_meta"` (default) or
  # `:_meta`. The function reads the two keys, merges their entries and
  # writes the result under `meta_key` only. On a clash of an entry
  # between the two keys, the entry of the atom key wins: the atom key is
  # the key of the code of the application. A value of `_meta` that is not
  # a map is ignored. A `nil` task id gives `params` back. A `nil` params
  # is an empty map.
  #
  @spec put(map() | nil, String.t() | nil, String.t() | atom()) :: map() | nil
  def put(params, task_id, meta_key \\ "_meta")

  def put(params, nil, _meta_key), do: params

  def put(params, task_id, meta_key) when is_binary(task_id) do
    params = params || %{}
    meta = merge_meta(Map.get(params, "_meta"), Map.get(params, :_meta))

    params
    |> Map.delete("_meta")
    |> Map.delete(:_meta)
    |> Map.put(meta_key, Map.merge(meta, meta(task_id)))
  end

  # The atom key wins on a clash: it is the key of the code of the
  # application. A value that is not a map is ignored.
  #
  defp merge_meta(string_meta, atom_meta), do: Map.merge(as_map(string_meta), as_map(atom_meta))

  defp as_map(meta) when is_map(meta), do: meta
  defp as_map(_other), do: %{}
end
