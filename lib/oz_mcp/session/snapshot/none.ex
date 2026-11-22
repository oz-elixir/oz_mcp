defmodule OzMcp.Session.Snapshot.None do
  @moduledoc "The default snapshot module: no persistence."

  @behaviour OzMcp.Session.Snapshot

  @impl true
  def save(_instance, _session_id, _snapshot), do: :ok

  @impl true
  def load(_instance, _session_id), do: :not_found

  @impl true
  def delete(_instance, _session_id), do: :ok
end
