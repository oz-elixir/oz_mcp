defmodule OzMcp.Tasks.EtsStore do
  @moduledoc """
  ETS record store of the tasks of one instance: the default store of
  the option `:task_store` and it implements
  `OzMcp.Tasks.StoreBehaviour`. One named table per instance (the
  records table, `table/1`). The index of the records lives in
  OzMcp.Tasks.Index: this store implements none of the optional
  callbacks of the contract, so the facade OzMcp.Tasks.Records keeps
  that index for it.

  A separate owner process (OzMcp.Tasks.Table) calls `init/1` and owns
  the tables. The tables are `:public`: the process of a task writes its
  own record and the request processes read the records. A crash of
  the owner deletes the records of the instance.

  Hazard: the record keeps a snapshot of the principal that created the
  task (`principal`), because the runner runs after the request ends, so
  the check of the token cannot be replayed. It never holds the raw
  token.
  """

  @behaviour OzMcp.Tasks.StoreBehaviour

  @enforce_keys [:task_id, :session_id, :seq, :status, :created_at, :last_updated_at]
  defstruct [
    :task_id,
    :session_id,
    :seq,
    :status,
    :created_at,
    :last_updated_at,
    :ttl,
    :poll_interval,
    :progress_token,
    :tool,
    :result,
    :runner_pid,
    :principal,
    :owner_key,
    :required_scopes,
    :expires_at_ms,
    :pid,
    status_message: nil,
    client_capabilities: %{},
    bytes: 0
  ]

  @type status :: OzMcp.Structs.Task.status()

  @type result ::
          {:ok, map()}
          | {:error, %{code: integer(), message: String.t(), data: term()}}
          | nil

  @type t() :: %__MODULE__{
          task_id: String.t(),
          session_id: String.t(),
          seq: non_neg_integer(),
          status: status(),
          status_message: String.t() | nil,
          created_at: DateTime.t(),
          last_updated_at: DateTime.t(),
          ttl: non_neg_integer() | nil,
          poll_interval: non_neg_integer() | nil,
          progress_token: String.t() | integer() | nil,
          tool: {module(), String.t()},
          result: result(),
          runner_pid: pid() | nil,
          principal: OzMcp.Auth.Principal.t() | nil,
          owner_key: term(),
          required_scopes: [String.t()] | nil,
          expires_at_ms: integer() | nil,
          pid: pid() | nil,
          client_capabilities: map(),
          bytes: non_neg_integer()
        }

  @doc "Creates the named ETS table of the records for the given instance."
  @impl true
  @spec init(atom()) :: :ok
  def init(instance) do
    _ = :ets.new(table(instance), [:set, :named_table, :public, read_concurrency: true])
    :ok
  end

  @doc "Returns the name of the records table for the given instance."
  @spec table(atom()) :: atom()
  def table(instance), do: Module.concat(instance, TasksTable)

  @doc "Writes the record."
  @impl true
  @spec put(atom(), t()) :: :ok
  def put(instance, record) do
    :ets.insert(table(instance), {record.task_id, record})
    :ok
  end

  @doc "Returns `{:ok, record}` or `:not_found`."
  @impl true
  @spec get(atom(), String.t()) :: {:ok, t()} | :not_found
  def get(instance, task_id) do
    case :ets.lookup(table(instance), task_id) do
      [{^task_id, record}] -> {:ok, record}
      [] -> :not_found
    end
  end

  @doc "Removes the record."
  @impl true
  @spec delete(atom(), t()) :: :ok
  def delete(instance, record) do
    :ets.delete(table(instance), record.task_id)
    :ok
  end

  @doc "The records with the status `:working` or `:input_required`."
  @impl true
  @spec active(atom()) :: [t()]
  def active(instance) do
    spec = [
      {{:_, %{status: :"$1"}}, [{:orelse, {:==, :"$1", :working}, {:==, :"$1", :input_required}}],
       [:"$_"]}
    ]

    instance
    |> table()
    |> :ets.select(spec)
    |> Enum.map(&elem(&1, 1))
  end

  @doc "Returns the deadline of the record in Unix milliseconds, or `nil`."
  @spec deadline_ms(t()) :: integer() | nil
  def deadline_ms(%{ttl: nil}), do: nil

  def deadline_ms(%{ttl: ttl, created_at: created_at}),
    do: DateTime.to_unix(created_at, :millisecond) + ttl

  @doc "Returns true when the record ttl (ms from creation) has elapsed."
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(record, now \\ DateTime.utc_now()) do
    case deadline_ms(record) do
      nil -> false
      deadline -> deadline <= DateTime.to_unix(now, :millisecond)
    end
  end
end
