#
# The processes that do the work of an instance. Each child restarts
# alone. No child owns state that another child needs to live.
#
defmodule OzMcp.Instance.Workers do
  @moduledoc false

  use Supervisor

  alias OzMcp.Instance
  alias OzMcp.Session.Snapshot

  # A `:kill` of this supervisor does not wait for its children. A child
  # of the old supervisor can still hold its `via` name when `Instance`
  # starts the new one and one child of `:tasks` can use the default 5 s
  # shutdown of a child. The start waits for the old children.
  #
  @stale_workers_ms 6_000

  def start_link(config) do
    Instance.start_retry(
      fn -> Supervisor.start_link(__MODULE__, config) end,
      @stale_workers_ms
    )
  end

  def child_spec(config) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [config]}, type: :supervisor}
  end

  @impl true
  def init(%{name: name, opts: opts} = config) do
    children =
      [
        {Task.Supervisor, name: Instance.via(name, :calls)},
        {DynamicSupervisor,
         name: Instance.via(name, :sessions),
         strategy: :one_for_one,
         max_children: opts.max_sessions || :infinity},
        {OzMcp.Tasks.Reaper, config},
        {DynamicSupervisor, name: Instance.via(name, :tasks), strategy: :one_for_one}
      ] ++ snapshot_specs(name, opts)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp snapshot_specs(_name, %{session_snapshot: Snapshot.None}), do: []

  defp snapshot_specs(name, opts) do
    [
      {OzMcp.Session.RestoreCache, {name, opts}},
      {OzMcp.Session.Snapshot.Writer, {name, opts}}
    ]
  end
end
