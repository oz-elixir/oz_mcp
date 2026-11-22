defmodule OzMcp.Sessions.Reclaim do
  @moduledoc false

  alias OzMcp.Instance
  alias OzMcp.Session
  alias OzMcp.Session.View
  alias OzMcp.Sessions

  @attempts 5

  @type scope :: :instance | {:principal, Sessions.principal_key()}

  # Ends one idle session of the scope, never `except_id`. `:ok` tells that a slot is free.
  #
  @spec run(Instance.t(), scope(), String.t() | nil) :: :ok | :none
  def run(instance, scope, except_id) do
    instance
    |> candidates(scope)
    |> Enum.reject(fn {id, _initialized, _at} -> id == except_id end)
    |> Enum.sort_by(fn {_id, initialized, at} -> {initialized, at} end)
    |> Enum.take(@attempts)
    |> Enum.find_value(:none, fn {id, _initialized, _at} ->
      if Session.evict(instance, id) == :ok, do: :ok
    end)
  end

  defp candidates(instance, :instance) do
    view = %{__struct__: View, streams: 0, initialized: :"$2", last_active_ms: :"$3"}
    spec = [{{{:session, :"$1"}, :_, view}, [], [{{:"$1", :"$2", :"$3"}}]}]

    Instance.select(instance, spec)
  end

  defp candidates(instance, {:principal, key}) do
    case Sessions.list_principal(instance, key) do
      {:ok, ids} ->
        for id <- ids,
            {:ok, %View{streams: 0} = view} <- [Sessions.lookup(instance, id)],
            do: {id, view.initialized, view.last_active_ms}

      _error ->
        []
    end
  end
end
