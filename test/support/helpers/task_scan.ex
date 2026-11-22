#
# The slow count of the active task records: a scan of the records table
# of an instance. The tests of the task counters use it as the reference
# that the counters of the default index must match.
#
defmodule Support.Helpers.TaskScan do
  alias OzMcp.Tasks.EtsStore
  alias OzMcp.Tasks.Records

  @spec active(atom(), {:owner, term()} | {:session, String.t()}) :: non_neg_integer()
  def active(instance, {kind, value}) do
    field = if kind == :owner, do: :owner_key, else: :session_id

    spec = [
      {{:_, %{status: :"$1"} |> Map.put(field, :"$2")},
       [
         {:andalso, {:==, :"$2", {:const, value}},
          {:orelse, {:==, :"$1", :working}, {:==, :"$1", :input_required}}}
       ], [true]}
    ]

    :ets.select_count(EtsStore.table(instance), spec)
  end

  # All the records of the records table, in no order.
  #
  @spec all(atom()) :: [EtsStore.t()]
  def all(instance), do: instance |> EtsStore.table() |> :ets.tab2list() |> Enum.map(&elem(&1, 1))

  # The records of an owner, in the order of `seq` (the order of the owner index).
  #
  @spec all_by_owner(atom(), term()) :: [EtsStore.t()]
  def all_by_owner(instance, owner_key) do
    {records, nil} = Records.page(EtsStore, instance, owner_key, 0, :infinity)
    records
  end
end
