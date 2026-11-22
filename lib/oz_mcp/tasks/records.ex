#
# Use `OzMcp` and the task methods of the protocol.
#
# The facade of the task store: it takes the store module of the option
# `:task_store` and dispatches to the store or to the default index.
#
# A store that implements the optional index callbacks of
# `OzMcp.Tasks.StoreBehaviour` owns its index; the boot refuses a partial
# set. The order of the steps keeps the counters of the default index
# crash-safe (see `OzMcp.Tasks.Index`).
#
defmodule OzMcp.Tasks.Records do
  @moduledoc false

  alias OzMcp.Tasks.EtsStore
  alias OzMcp.Tasks.Index

  @type instance :: OzMcp.Tasks.StoreBehaviour.instance()

  @index_callbacks [page: 4, count_active: 2, expired: 3, next_expiry: 1, owner_usage: 2]

  # The optional index callbacks of the store contract.
  #
  @spec index_callbacks() :: [{atom(), non_neg_integer()}]
  def index_callbacks, do: @index_callbacks

  # True when the store implements the optional index callbacks.
  #
  @spec own_index?(module()) :: boolean()
  def own_index?(store) do
    Code.ensure_loaded?(store) and function_exported?(store, :page, 4)
  end

  # Runs the init of the store and, when it does not own its index, the init of the default index.
  #
  @spec init(module(), instance()) :: :ok
  def init(store, instance) do
    with :ok <- store.init(instance) do
      unless own_index?(store), do: Index.init(instance)
      :ok
    end
  end

  # A broken store can answer an error of its own: the callers treat an
  # answer of another shape as a failure.
  #
  @type read_answer :: {:ok, EtsStore.t()} | :not_found | {:error, term()}

  # Reads one record of the store.
  #
  @spec get(module(), instance(), String.t()) :: read_answer()
  def get(store, instance, task_id), do: store.get(instance, task_id)

  # Writes a record. The call sets `bytes` to an estimate of the size of
  # the record, for every store. When the store does not own its index,
  # the call runs the two steps of the index around the write.
  #
  @spec put(module(), instance(), EtsStore.t()) :: :ok | {:error, term()}
  def put(store, instance, record) do
    record = %{record | bytes: size(record)}

    if own_index?(store) do
      store.put(instance, record)
    else
      with {:ok, old} <- stored(store, instance, record.task_id) do
        Index.before_put(instance, old, record)

        with :ok <- store.put(instance, record) do
          Index.after_put(instance, old, record)
        end
      end
    end
  end

  # Deletes a record. When the store does not own its index, the call
  # runs the two steps of the index around the delete.
  #
  @spec delete(module(), instance(), EtsStore.t()) :: :ok | {:error, term()}
  def delete(store, instance, record) do
    if own_index?(store) do
      store.delete(instance, record)
    else
      with {:ok, stored} <- stored(store, instance, record.task_id) do
        Index.before_delete(instance, stored)

        with :ok <- store.delete(instance, record) do
          Index.after_delete(instance, record, stored)
        end
      end
    end
  end

  # The page of the records of an owner, from the store or from the default index.
  #
  @spec page(module(), instance(), term(), non_neg_integer(), pos_integer()) ::
          {[EtsStore.t()], non_neg_integer() | nil}
  def page(store, instance, owner_key, after_seq, limit) do
    if own_index?(store),
      do: store.page(instance, owner_key, after_seq, limit),
      else: Index.page(store, instance, owner_key, after_seq, limit)
  end

  # The number of the active records of an owner or of a session. A store
  # that answers an error gives `{:error, reason}`.
  #
  @spec count_active(module(), instance(), {:owner, term()} | {:session, String.t()}) ::
          non_neg_integer() | {:error, term()}
  def count_active(store, instance, key) do
    if own_index?(store),
      do: store.count_active(instance, key),
      else: Index.count_active(instance, key)
  end

  # The records of the store whose ttl has elapsed, the oldest first.
  #
  @spec expired(module(), instance(), integer(), pos_integer()) :: [EtsStore.t()]
  def expired(store, instance, now_ms, limit) do
    if own_index?(store),
      do: store.expired(instance, now_ms, limit),
      else: Index.expired(store, instance, now_ms, limit)
  end

  # The smallest expiry time in the store, or `nil`.
  #
  @spec next_expiry(module(), instance()) :: integer() | nil
  def next_expiry(store, instance) do
    if own_index?(store),
      do: store.next_expiry(instance),
      else: Index.next_expiry(instance)
  end

  # The number of all the records of an owner and the sum of their bytes.
  # A store that answers an error gives `{:error, reason}`.
  #
  @spec owner_usage(module(), instance(), term()) ::
          {non_neg_integer(), non_neg_integer()} | {:error, term()}
  def owner_usage(store, instance, owner_key) do
    if own_index?(store),
      do: store.owner_usage(instance, owner_key),
      else: Index.owner_usage(instance, owner_key)
  end

  # The size of the record without the old value of `bytes`.
  #
  defp size(record), do: :erlang.external_size(%{record | bytes: 0})

  # The stored record is the truth for the counters and for the expiry
  # key. A read that fails must not look like a missing record: the
  # caller would raise the counters again for a record it counted.
  #
  @spec stored(module(), instance(), String.t()) ::
          {:ok, EtsStore.t() | nil} | {:error, term()}
  defp stored(store, instance, task_id) do
    case store.get(instance, task_id) do
      {:ok, record} -> {:ok, record}
      :not_found -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end
end
