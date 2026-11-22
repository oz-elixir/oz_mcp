defmodule OzMcp.Tasks.StoreBehaviour do
  @moduledoc """
  The contract of a task store (the `:task_store` option of
  `OzMcp`, default `OzMcp.Tasks.EtsStore`).

  The task process writes its own record. The request processes and the
  reaper read the records. A store must accept calls from many processes
  and the writes of one record come from one process at a time.

  The records are `OzMcp.Tasks.EtsStore.t()` structs. A store can index
  a record by two fields: `owner_key` and `seq` (the pages of `page/4`
  list the records of one owner in the order of `seq`) and
  `expires_at_ms` (only a terminal record has it; `expired/3` and
  `next_expiry/1` read this index).

  Five callbacks of the contract are optional: `page/4`, `count_active/2`,
  `expired/3`, `next_expiry/1` and `owner_usage/2`. A store must
  implement all five or none of them: the boot refuses a partial set. A
  store with none of them uses the default index OzMcp.Tasks.Index,
  which the facade OzMcp.Tasks.Records keeps around each write and
  each delete. A store that implements the five owns its index: the
  facade calls it and keeps no index of its own.

  The default index lives in the memory of one node: it starts empty at
  a restart of the node and it cannot rebuild itself from the records
  of the store. A store that keeps its records after a restart, or that
  several nodes share, must therefore implement the five optional
  callbacks itself.

  The field `seq` comes from `System.unique_integer/1`. It starts again
  at 1 each time the VM starts, so it is not unique across restarts. A
  store that keeps records after a restart must give `page/4` an order
  that does not depend on this value, or it must give the records a new
  `seq` when it loads them. The cursor of `tasks/list` is the `seq` of
  the last record of the page. The default store loses all its records
  with the VM, so it has no problem.

  A store can also implement the optional `active/1`: the reaper calls
  it at start and it marks each record whose process is dead as
  `failed`. A store that does not implement it has no recovery of the
  records of an earlier run.

  `count_active/2` counts the records of a session or of an owner whose
  status is `:working` or `:input_required`; the checks of the limits
  read it. `owner_usage/2` gives the number of all the records of an
  owner and the sum of their `bytes`. A store that owns its index keeps
  its own counters for each session and each owner: it must not
  delegate only these callbacks to OzMcp.Tasks.Index, which would
  count `0`.
  """

  alias OzMcp.Tasks.EtsStore, as: Record

  @type instance :: atom()

  @callback init(instance()) :: :ok
  @callback put(instance(), Record.t()) :: :ok
  @callback get(instance(), task_id :: String.t()) :: {:ok, Record.t()} | :not_found
  @callback delete(instance(), Record.t()) :: :ok
  @callback page(
              instance(),
              owner_key :: term(),
              after_seq :: non_neg_integer(),
              limit :: pos_integer()
            ) :: {[Record.t()], next_seq :: non_neg_integer() | nil}
  @callback count_active(instance(), {:owner, term()} | {:session, String.t()}) ::
              non_neg_integer()
  @callback expired(instance(), now_ms :: integer(), limit :: pos_integer()) :: [Record.t()]
  @callback next_expiry(instance()) :: integer() | nil
  @callback owner_usage(instance(), owner_key :: term()) ::
              {non_neg_integer(), non_neg_integer()}

  @doc """
  Returns the records with the status `:working` or `:input_required`.
  """
  @callback active(instance()) :: [Record.t()]

  @optional_callbacks active: 1,
                      page: 4,
                      count_active: 2,
                      expired: 3,
                      next_expiry: 1,
                      owner_usage: 2
end
