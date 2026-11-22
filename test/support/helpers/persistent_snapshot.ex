#
# A snapshot module for the tests. Its table belongs to a holder process
# that `test_helper.exs` starts one time for the whole run: a restart of
# an instance keeps the snapshots. Every entry is keyed by the name of
# the instance, so the tests of different files (and the tests of one
# file) hold their state apart and can run at the same time.
#
# A test makes a function of one instance fail with `fail/3` and counts
# the calls of one instance with `calls/2`.
#
defmodule Support.Helpers.PersistentSnapshot do
  @behaviour OzMcp.Session.Snapshot

  @holder __MODULE__
  @table __MODULE__

  # Starts the holder of the table. The test helper calls it one time.
  #
  def start_link do
    Agent.start_link(
      fn ->
        :ets.new(@table, [:named_table, :public, :set])
        :ok
      end,
      name: @holder
    )
  end

  # Makes `function` (`:save`, `:load` or `:delete`) of `instance` fail:
  # `:raise`, `:throw`, `:exit` or `:error`.
  #
  def fail(instance, function, kind), do: put({{:fail, instance, function}, kind})

  # Makes `function` (`:save`, `:load` or `:delete`) of `instance` sleep
  # `ms` milliseconds before it runs.
  #
  def slow(instance, function, ms), do: put({{:slow, instance, function}, ms})

  # Removes the delay of `function` of `instance`.
  #
  def clear_slow(instance, function), do: drop({:slow, instance, function})

  # Makes `function` of `instance` work again.
  #
  def heal(instance, function), do: drop({:fail, instance, function})

  # The number of calls of `function` of `instance`.
  #
  def calls(instance, function) do
    case :ets.lookup(@table, {:calls, instance, function}) do
      [{_key, count}] -> count
      [] -> 0
    end
  end

  # The snapshot of a session of `instance`, or nil.
  #
  def get(instance, session_id) do
    case :ets.lookup(@table, {:snapshot, instance, session_id}) do
      [{_key, snapshot}] -> snapshot
      [] -> nil
    end
  end

  # Writes a snapshot for a session id that no session process of `instance`
  # keeps: the next read of the id starts the session again from the
  # snapshot.
  #
  def put(instance, session_id, snapshot) do
    :ets.insert(@table, {{:snapshot, instance, session_id}, snapshot})
    :ok
  end

  @impl true
  def save(instance, session_id, snapshot) do
    run(instance, :save, fn ->
      :ets.insert(@table, {{:snapshot, instance, session_id}, snapshot})
      :ok
    end)
  end

  @impl true
  def load(instance, session_id) do
    run(instance, :load, fn ->
      case get(instance, session_id) do
        nil -> :not_found
        snapshot -> {:ok, snapshot}
      end
    end)
  end

  @impl true
  def delete(instance, session_id) do
    run(instance, :delete, fn ->
      :ets.delete(@table, {:snapshot, instance, session_id})
      :ok
    end)
  end

  defp put(record) do
    if :ets.info(@table) == :undefined, do: :ok, else: :ets.insert(@table, record)

    :ok
  end

  defp drop(key) do
    if :ets.info(@table) != :undefined, do: :ets.delete(@table, key)

    :ok
  end

  defp run(instance, function, fun) do
    :ets.update_counter(
      @table,
      {:calls, instance, function},
      1,
      {{:calls, instance, function}, 0}
    )

    case :ets.lookup(@table, {:slow, instance, function}) do
      [{_key, ms}] when is_integer(ms) and ms > 0 -> Process.sleep(ms)
      _no_delay -> :ok
    end

    case :ets.lookup(@table, {:fail, instance, function}) do
      [{_key, :raise}] -> raise "snapshot #{function} failed"
      [{_key, :throw}] -> throw(:snapshot_failure)
      [{_key, :exit}] -> exit(:snapshot_failure)
      [{_key, :error}] -> {:error, :snapshot_failure}
      [] -> fun.()
    end
  end
end
