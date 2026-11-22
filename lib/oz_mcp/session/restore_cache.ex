#
# The cache of the session ids that the snapshot module of the instance
# did not find and the tombstones of the ids whose delete did not end
# yet: a restore of such an id gets no session, with no call to the
# store of the user. One process for each instance owns the tables and
# sweeps the entries that passed their time; the functions of the cache
# run in the caller.
#
# Hazard: a crash of the process loses the tombstones, so a restore of
# the id of a delete that did not end yet can start the session again.
#
defmodule OzMcp.Session.RestoreCache do
  @moduledoc false

  use GenServer

  alias OzMcp.Instance

  # A flood of unknown ids fills the table; a miss that arrives while it
  # is full reaches the store again until the sweep frees entries.
  #
  @max_entries 10_000

  # The sweep never runs faster than once per this time. An entry holds
  # its own time (`missing?/2` compares it), so a late sweep only delays
  # the moment the entry frees its space.
  #
  @min_sweep_ms 1_000

  # The hold time of a tombstone: a failed delete keeps the mark for
  # this time, then a restore of the id can read the store again.
  #
  @tombstone_hold_ms 60_000

  def child_spec({name, opts}) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [{name, opts}]}}
  end

  def start_link({name, opts}) do
    GenServer.start_link(__MODULE__, {name, opts}, name: Instance.via(name, :restore_cache))
  end

  # True when the store did not find the id and the miss is still held.
  # A table that does not exist is no miss.
  #
  @doc false
  @spec missing?(Instance.t(), String.t()) :: boolean()
  def missing?(instance, id) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(table(instance), id) do
      [{^id, expires_at}] -> expires_at > now
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  # Holds the miss of an id for `ttl_ms`. `0` holds nothing: the cache is
  # off. The size check and the insert are two steps: misses that arrive
  # together can go over the cap.
  #
  @doc false
  @spec put_missing(Instance.t(), String.t(), non_neg_integer()) :: :ok
  def put_missing(_instance, _id, 0), do: :ok

  def put_missing(instance, id, ttl_ms) do
    table = table(instance)

    if :ets.info(table, :size) < @max_entries do
      :ets.insert(table, {id, System.monotonic_time(:millisecond) + ttl_ms})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  # Marks the id as deleted: a restore gives no session until
  # `clear_deleted/2`, or until the hold time passes.
  #
  @doc false
  @spec put_deleted(Instance.t(), String.t()) :: :ok
  def put_deleted(instance, id) do
    :ets.insert(
      tombstones(instance),
      {id, System.monotonic_time(:millisecond) + @tombstone_hold_ms}
    )

    :ok
  rescue
    ArgumentError -> :ok
  end

  # True while the mark of the id is held.
  #
  @doc false
  @spec deleted?(Instance.t(), String.t()) :: boolean()
  def deleted?(instance, id) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(tombstones(instance), id) do
      [{^id, expires_at}] -> expires_at > now
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  # The delete of the store ended with `:ok`: the store holds nothing.
  #
  @doc false
  @spec clear_deleted(Instance.t(), String.t()) :: :ok
  def clear_deleted(instance, id) do
    :ets.delete(tombstones(instance), id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # The names of the tables are per instance: a miss or a tombstone that
  # one instance holds is unknown to the other.
  #
  defp table(instance), do: Module.concat(instance, __MODULE__)

  defp tombstones(instance), do: Module.concat([instance, __MODULE__, Tombstones])

  @impl true
  def init({name, opts}) do
    ttl = Map.fetch!(opts, :session_restore_miss_ttl_ms)
    _ = :ets.new(table(name), [:named_table, :public, :set, read_concurrency: true])
    _ = :ets.new(tombstones(name), [:named_table, :public, :set, read_concurrency: true])
    timer = Process.send_after(self(), :sweep, sweep_after(ttl))
    {:ok, %{name: name, ttl: ttl, timer: timer}}
  end

  @impl true
  def handle_info(:sweep, %{name: name, ttl: ttl} = state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(table(name), expired_spec(now))
    :ets.select_delete(tombstones(name), expired_spec(now))
    timer = Process.send_after(self(), :sweep, sweep_after(ttl))
    {:noreply, %{state | timer: timer}}
  end

  # The hold time of the tombstones caps the ttl from above.
  #
  defp sweep_after(ttl), do: max(min(ttl, @tombstone_hold_ms), @min_sweep_ms)

  defp expired_spec(now) do
    [{{:"$1", :"$2"}, [{:"=<", :"$2", {:const, now}}], [true]}]
  end
end
