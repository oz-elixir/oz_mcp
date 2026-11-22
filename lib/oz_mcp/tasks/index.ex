#
# The default index of the task records for a store that implements none
# of the optional callbacks: the owner pages, the expiry index and the
# counters, in three named ETS tables per instance.
#
# The counters never go too high: a decrement runs before the write of
# the store and an increment after it.
#
defmodule OzMcp.Tasks.Index do
  @moduledoc false

  alias OzMcp.Tasks.EtsStore

  @type instance :: OzMcp.Tasks.StoreBehaviour.instance()

  # A record with one of these statuses holds a slot of the limits.
  #
  @active [:working, :input_required]

  # Creates the three named ETS tables for the given instance.
  #
  @spec init(instance()) :: :ok
  def init(instance) do
    for name <- [index_table(instance), expiry_table(instance)] do
      _ = :ets.new(name, [:ordered_set, :named_table, :public, read_concurrency: true])
    end

    _ =
      :ets.new(counters_table(instance), [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    :ok
  end

  # Returns the name of the owner index for the given instance.
  #
  @spec index_table(instance()) :: atom()
  def index_table(instance), do: Module.concat(instance, TasksIndex)

  # Returns the name of the expiry index for the given instance.
  #
  @spec expiry_table(instance()) :: atom()
  def expiry_table(instance), do: Module.concat(instance, TasksExpiry)

  # Returns the name of the active counters table for the given instance.
  #
  @spec counters_table(instance()) :: atom()
  def counters_table(instance), do: Module.concat(instance, TasksCounters)

  # The decrement of the counters of the old record, before the store writes.
  #
  @spec before_put(instance(), EtsStore.t() | nil, EtsStore.t()) :: :ok
  def before_put(instance, old, record) do
    if active?(old) and not active?(record), do: bump(instance, old, -1)

    if old && old.expires_at_ms,
      do: :ets.delete(expiry_table(instance), {old.expires_at_ms, record.task_id})

    if old && record.bytes < old.bytes,
      do: add(instance, {:bytes, old.owner_key}, record.bytes - old.bytes)

    :ok
  end

  # The index entries and the increment of the counters, after the store wrote.
  #
  @spec after_put(instance(), EtsStore.t() | nil, EtsStore.t()) :: :ok
  def after_put(instance, old, record) do
    :ets.insert(index_table(instance), {{record.owner_key, record.seq}, record.task_id})

    if record.expires_at_ms,
      do: :ets.insert(expiry_table(instance), {{record.expires_at_ms, record.task_id}})

    if active?(record) and not active?(old), do: bump(instance, record, 1)

    case old do
      nil ->
        add(instance, {:records, record.owner_key}, 1)
        add(instance, {:bytes, record.owner_key}, record.bytes)

      %{bytes: old_bytes} when record.bytes > old_bytes ->
        add(instance, {:bytes, record.owner_key}, record.bytes - old_bytes)

      _other ->
        :ok
    end

    :ok
  end

  # The decrement of the counters of the stored record, before the store deletes.
  #
  @spec before_delete(instance(), EtsStore.t() | nil) :: :ok
  def before_delete(instance, stored) do
    if active?(stored), do: bump(instance, stored, -1)

    if stored do
      add(instance, {:records, stored.owner_key}, -1)
      add(instance, {:bytes, stored.owner_key}, -stored.bytes)
    end

    :ok
  end

  # The removal of the index entries, after the store deleted. The caller
  # gives the record it read before and the stored record: the expiry
  # index can hold an entry for each of the two.
  #
  @spec after_delete(instance(), EtsStore.t(), EtsStore.t() | nil) :: :ok
  def after_delete(instance, record, stored) do
    :ets.delete(index_table(instance), {record.owner_key, record.seq})

    for %{expires_at_ms: at} when at != nil <- Enum.uniq([record, stored || record]),
        do: :ets.delete(expiry_table(instance), {at, record.task_id})

    :ok
  end

  defp active?(%{status: status}), do: status in @active
  defp active?(nil), do: false

  defp bump(instance, record, delta) do
    for key <- [{:session, record.session_id}, {:owner, record.owner_key}],
        do: add(instance, key, delta)

    :ok
  end

  defp add(instance, key, delta) do
    table = counters_table(instance)

    # A decrement stops at 0 (threshold 0, set value 0).
    #
    op = if delta < 0, do: {2, delta, 0, 0}, else: {2, delta}
    new = :ets.update_counter(table, key, op, {key, 0})

    # A zero entry goes: one entry for each session that ever ran a task
    # would grow without limit. `delete_object/2` removes the exact
    # object only, so a concurrent increment keeps its entry.
    #
    if new == 0, do: :ets.delete_object(table, {key, 0})

    :ok
  end

  # The number of the active records of an owner or of a session.
  #
  @spec count_active(instance(), {:owner, term()} | {:session, String.t()}) :: non_neg_integer()
  def count_active(instance, {kind, _value} = key) when kind in [:owner, :session],
    do: read(instance, key)

  # The number of all the records of an owner and the sum of their `bytes`.
  #
  @spec owner_usage(instance(), term()) :: {non_neg_integer(), non_neg_integer()}
  def owner_usage(instance, owner_key) do
    {read(instance, {:records, owner_key}), read(instance, {:bytes, owner_key})}
  end

  defp read(instance, key) do
    case :ets.lookup(counters_table(instance), key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end

  # Returns at most `limit` records whose `expires_at_ms` is at or before `now_ms`.
  #
  @spec expired(module(), instance(), integer(), pos_integer()) :: [EtsStore.t()]
  def expired(store, instance, now_ms, limit) do
    expiry = expiry_table(instance)

    expiry
    |> expired_keys(:ets.first(expiry), now_ms, limit, [])
    |> Enum.flat_map(fn {_at, task_id} ->
      case store.get(instance, task_id) do
        {:ok, record} -> [record]
        _gone -> []
      end
    end)
  end

  defp expired_keys(_expiry, :"$end_of_table", _now, _limit, acc), do: Enum.reverse(acc)
  defp expired_keys(_expiry, _key, _now, 0, acc), do: Enum.reverse(acc)

  defp expired_keys(expiry, {at, _task_id} = key, now, limit, acc) when at <= now,
    do: expired_keys(expiry, :ets.next(expiry, key), now, limit - 1, [key | acc])

  defp expired_keys(_expiry, _key, _now, _limit, acc), do: Enum.reverse(acc)

  # Returns the smallest `expires_at_ms` of the expiry index, or `nil`.
  #
  @spec next_expiry(instance()) :: integer() | nil
  def next_expiry(instance) do
    case :ets.first(expiry_table(instance)) do
      :"$end_of_table" -> nil
      {at, _task_id} -> at
    end
  end

  # Cursor pagination over the owner index: `{records, next_cursor | nil}`.
  #
  @spec page(module(), instance(), term(), non_neg_integer(), pos_integer()) ::
          {[EtsStore.t()], non_neg_integer() | nil}
  def page(store, instance, owner_key, after_seq, limit),
    do: collect(store, instance, owner_key, after_seq, limit)

  defp collect(store, instance, owner_key, after_seq, limit) do
    index = index_table(instance)
    next = :ets.next(index, {owner_key, after_seq})

    do_collect(store, instance, index, owner_key, next, limit, [])
  end

  defp do_collect(_store, _instance, _index, _owner, :"$end_of_table", _limit, acc),
    do: {Enum.reverse(acc), nil}

  # Another page exists only if the next key still belongs to the owner.
  #
  defp do_collect(_store, _instance, _index, owner_key, {owner_key, _seq}, 0, [last | _] = acc),
    do: {Enum.reverse(acc), last.seq}

  defp do_collect(_store, _instance, _index, _owner, _key, 0, acc), do: {Enum.reverse(acc), nil}

  defp do_collect(store, instance, index, owner_key, {owner_key, _seq} = key, limit, acc) do
    next_limit = if limit == :infinity, do: :infinity, else: limit - 1

    with [{^key, task_id}] <- :ets.lookup(index, key),
         {:ok, record} <- store.get(instance, task_id) do
      do_collect(
        store,
        instance,
        index,
        owner_key,
        :ets.next(index, key),
        next_limit,
        [record | acc]
      )
    else
      :not_found ->
        do_collect(store, instance, index, owner_key, :ets.next(index, key), limit, acc)

      _gone ->
        {Enum.reverse(acc), nil}
    end
  end

  # First key of another owner: the range of this owner is exhausted.
  #
  defp do_collect(_store, _instance, _index, _owner, _key, _limit, acc),
    do: {Enum.reverse(acc), nil}
end
