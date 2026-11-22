defmodule OzMcp.Tasks do
  @moduledoc """
  The tasks of an instance (MCP 2025-11-25, "Tasks").

  Each function takes the instance as its first argument. A call that
  cannot get an answer gives `{:error, :unavailable}` (the instance is
  not running, or the process of the tasks exited) or
  `{:error, :timeout}` (no answer in time). A task that does not exist,
  or that belongs to another owner, gives `{:error, :no_task}`.

  The owner of a task is the principal that created it, or its session
  when the server has no authorization (see `owner_key/1`). The sessions
  of one principal see the same tasks.
  """

  alias OzMcp.Auth.{Principal, Scopes}
  alias OzMcp.Handler.Output
  alias OzMcp.Instance
  alias OzMcp.Structs.Task
  alias OzMcp.Tasks.EtsStore
  alias OzMcp.Tasks.Reaper
  alias OzMcp.Tasks.Records
  alias OzMcp.Telemetry
  alias OzMcp.Utils.Generator
  alias OzMcp.Wire

  @type error :: {:error, :no_task | :unavailable | :timeout | term()}

  @typedoc """
  The limit that refused a create: the name of the runtime option and
  the value of `:limit` in the telemetry event `[:limit, :reached]`.
  """
  @type limit ::
          :max_tasks_per_session
          | :max_tasks_per_principal
          | :max_task_records_per_owner
          | :max_task_bytes_per_owner

  @call_timeout 5_000

  # The tries of `await/4` and `attach/6` cover a task process that
  # stopped while the call was in flight: a crashed process makes each
  # try fail at once (`:noproc`).
  #
  @await_attempts 3
  @terminal [:completed, :failed, :cancelled]
  @page_batch 100

  # The ceiling of any task ttl: 365 days, in milliseconds, also when
  # task_max_ttl_ms is nil. A larger value gives no useful task and
  # `:erlang.start_timer/4` raises on a very large value. The schema
  # holds the same literal for the boot check of the two ttl options.
  #
  @ttl_ceiling_ms 365 * 24 * 60 * 60 * 1000

  # The callers pass a context, which holds more keys than the two that
  # this function reads.
  #
  @doc "The owner key of the tasks of a request: the key of the principal, or the session id."
  @spec owner_key(%{
          required(:principal) => OzMcp.Auth.Principal.t() | nil,
          optional(:session_id) => String.t() | nil,
          optional(atom()) => term()
        }) :: term()
  def owner_key(%{principal: nil, session_id: session_id}), do: {:session, session_id}
  def owner_key(%{principal: principal}), do: {:principal, OzMcp.Auth.Principal.key(principal)}

  @doc """
  Starts a task: the tool of a task-augmented `tools/call` runs in a
  supervised runner, owned by a task process.

  The attributes carry `:session_id`, `:tool` (a `{module, name}` tuple)
  and `:request` (required only for a task that starts a runner).
  Optional keys: `:ttl`, `:progress_token`, `:client_capabilities`,
  `:principal`, `:required_scopes`, `:output_schema`, `:poll_interval`
  (the hint the tool's execution declares; the instance option
  `task_poll_interval_ms` is the default) and `:settled` (a task
  terminal at creation has no process and no status notification). A
  create refused by a limit gives `{:error, {:too_many_tasks, limit}}`,
  with `limit` the name of the refusing option.
  """
  @spec create(Instance.t(), map()) ::
          {:ok, Task.t()} | {:error, {:too_many_tasks, limit()}} | error()
  def create(instance, attrs) do
    with {:ok, config} <- fetch_config(instance) do
      record = new_record(attrs, config.opts)

      case attrs[:settled] do
        nil ->
          start_task(instance, config.opts, record, attrs)

        settled ->
          settle(instance, config.opts, record, settled)
      end
    end
  end

  @doc """
  Reads a task.
  """
  @spec get(Instance.t(), term(), String.t()) :: {:ok, Task.t()} | error()
  def get(instance, owner_key, task_id) do
    with {:ok, record} <- fetch_owned(instance, owner_key, task_id),
         do: {:ok, to_task(record)}
  end

  @doc """
  The tasks of an owner, oldest first, with the cursor of the next page
  (nil on the last page). The cursor is the opaque cursor of the previous
  page (nil for the first page). The limit is a number of tasks (nil for
  the page size of the instance). The page skips the expired records. A
  broken cursor gives `{:error, :invalid_cursor}`.

  With a principal, the page holds only the tasks whose scopes the
  principal holds and it reads more records until it has `limit`
  visible tasks or the index ends. No principal (an open server) shows
  every task.
  """
  @spec list(Instance.t(), term(), String.t() | nil, pos_integer() | nil, Principal.t() | nil) ::
          {:ok, [Task.t()], String.t() | nil} | error()
  def list(instance, owner_key, cursor, limit, principal \\ nil) do
    with {:ok, config} <- fetch_config(instance),
         {:ok, after_seq} <- parse_cursor(cursor) do
      limit = limit || config.opts.task_page_size

      {records, next_seq} =
        visible_page(instance, config.opts, owner_key, after_seq, limit, principal, [])

      next_cursor = if next_seq, do: Integer.to_string(next_seq)

      {:ok, Enum.map(records, &to_task/1), next_cursor}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  @doc """
  Reads the record of a task of an owner. Nothing changes: an expired
  record is reported but not removed. The scope stage of the pipeline
  reads the `required_scopes` of the record.
  """
  @spec peek(Instance.t(), term(), String.t()) :: {:ok, EtsStore.t()} | error()
  def peek(instance, owner_key, task_id) do
    case read_owned(instance, owner_key, task_id) do
      {:expired, _record} -> {:error, :expired}
      other -> other
    end
  end

  # The cursor is the seq of the last visible record: the next page
  # reads the hidden records after it.
  #
  defp visible_page(instance, opts, owner_key, after_seq, limit, principal, acc) do
    {records, next_seq} =
      Records.page(opts.task_store, instance, owner_key, after_seq, limit - length(acc))

    visible =
      records
      |> Enum.reject(&EtsStore.expired?/1)
      |> Enum.filter(&scopes_visible?(&1, principal))

    acc = acc ++ visible

    cond do
      next_seq == nil -> {acc, nil}
      length(acc) >= limit -> {acc, List.last(acc).seq}
      true -> visible_page(instance, opts, owner_key, next_seq, limit, principal, acc)
    end
  end

  defp scopes_visible?(_record, nil), do: true

  defp scopes_visible?(record, principal),
    do: Scopes.granted?(principal, record.required_scopes || [])

  @doc """
  Waits for the outcome of a task with no time limit: the wait ends at
  a terminal status, at the expiry of the task, or at the end of the
  session.
  """
  @spec await(Instance.t(), term(), String.t()) :: {:ok, term()} | error()
  def await(instance, owner_key, task_id), do: await(instance, owner_key, task_id, nil)

  @doc """
  Waits for the outcome of a task, with a limit of time.

  `timeout` is a number of milliseconds, or `nil` for no limit (the same
  as `await/3`). Gives `{:error, :timeout}` when the limit passes. The
  result of a cancelled task is the same error that `tasks/result` gives
  (-32800, "task was cancelled").
  """
  @spec await(Instance.t(), term(), String.t(), timeout() | nil) :: {:ok, term()} | error()
  def await(instance, owner_key, task_id, timeout),
    do: await(instance, owner_key, task_id, timeout, @await_attempts)

  defp await(instance, owner_key, task_id, timeout, attempts) do
    with {:ok, record} <- fetch_owned(instance, owner_key, task_id) do
      cond do
        record.status in @terminal ->
          {:ok, record.result}

        is_pid(record.pid) and attempts > 0 ->
          #
          # The task process owns the end of the wait: it enforces the
          # timeout of the caller. A stop during the wait gives an exit
          # and the retry reads the record.
          #
          case call_task(record.pid, {:await, timeout || :infinity}, :infinity) do
            {:gone, _reason} -> await(instance, owner_key, task_id, timeout, attempts - 1)
            answer -> answer
          end

        true ->
          reconcile_result(instance, owner_key, task_id)
      end
    end
  end

  @doc """
  Cancels a task: its runner stops, its status becomes `cancelled`. A
  task that is already terminal gives `{:error, {:terminal, status}}`.
  """
  @spec cancel(Instance.t(), term(), String.t()) :: {:ok, Task.t()} | error()
  def cancel(instance, owner_key, task_id) do
    with {:ok, record} <- fetch_owned(instance, owner_key, task_id) do
      cond do
        record.status in @terminal ->
          {:error, {:terminal, record.status}}

        is_pid(record.pid) ->
          case call_task(record.pid, :cancel, @call_timeout) do
            {:gone, _reason} -> cancel_after_exit(instance, owner_key, task_id)
            answer -> answer
          end

        true ->
          cancel_after_exit(instance, owner_key, task_id)
      end
    end
  end

  # A record still active with no live process: the reaper looks at the
  # task first, so a lost process gets its `failed` record first.
  #

  defp cancel_after_exit(instance, owner_key, task_id) do
    case fetch_owned(instance, owner_key, task_id) do
      {:ok, %{status: status}} when status in @terminal ->
        {:error, {:terminal, status}}

      {:ok, _active} ->
        with :ok <- Reaper.reconcile(instance, task_id),
             {:ok, %{status: status}} when status in @terminal <-
               fetch_owned(instance, owner_key, task_id) do
          {:error, {:terminal, status}}
        else
          {:error, _reason} = error -> error
          _still_active -> {:error, :unavailable}
        end

      error ->
        error
    end
  end

  # A record that went away in the meantime passes its answer on, so
  # all the callers give the same answer for the same record.
  #
  defp reconcile_result(instance, owner_key, task_id) do
    with :ok <- Reaper.reconcile(instance, task_id),
         {:ok, %{status: status, result: result}} when status in @terminal <-
           fetch_owned(instance, owner_key, task_id) do
      {:ok, result}
    else
      {:error, reason} = error when reason in [:expired, :no_task] -> error
      _still_active_or_error -> {:error, :unavailable}
    end
  end

  # A term that JSON cannot encode gives `{:error, :not_encodable}`. The
  # two entry points of the tools come through this function.
  #
  @doc false
  @spec progress(Instance.t(), String.t(), number(), number() | nil, term()) ::
          :ok | {:error, :not_encodable | :unavailable}
  def progress(instance, task_id, progress_value, total, message) do
    with {:ok, _data} <-
           Wire.encode_message(%{progress: progress_value, total: total, message: message}) do
      cast_task(instance, task_id, {:progress, progress_value, total, message})
    end
  end

  # A text that JSON cannot encode gives `{:error, :not_encodable}`.
  #
  @doc false
  @spec status_message(Instance.t(), String.t(), String.t() | nil) ::
          :ok | {:error, :not_encodable | :unavailable}
  def status_message(instance, task_id, message) do
    with {:ok, _data} <- Wire.encode_message(%{message: message}) do
      cast_task(instance, task_id, {:status_message, message})
    end
  end

  # `{:error, :no_task}` when the task does not run.
  #
  @doc false
  @spec request(Instance.t(), String.t(), String.t(), map() | nil) ::
          {:ok, String.t(), pid()} | {:error, :no_task | :not_encodable}
  def request(instance, task_id, method, params) do
    case Instance.whereis(instance, {:task, task_id}) do
      {:ok, pid} ->
        case :gen_statem.call(pid, {:request, self(), method, params}, @call_timeout) do
          {:ok, out_id} -> {:ok, out_id, pid}
          {:error, _reason} = error -> error
        end

      :not_running ->
        {:error, :no_task}
    end
  catch
    :exit, _reason -> {:error, :no_task}
  end

  @doc false

  @spec cancel_request(Instance.t(), String.t(), String.t()) :: :ok
  def cancel_request(instance, task_id, out_id) do
    case Instance.whereis(instance, {:task, task_id}) do
      {:ok, pid} ->
        _ = call_task(pid, {:cancel_request, out_id}, @call_timeout)
        :ok

      :not_running ->
        :ok
    end
  end

  @doc false
  @spec pending_request_ids(Instance.t(), String.t()) :: [String.t()]
  def pending_request_ids(instance, task_id) do
    case Instance.whereis(instance, {:task, task_id}) do
      {:ok, pid} ->
        try do
          {_state, data} = :sys.get_state(pid)
          Map.keys(data.held)
        catch
          :exit, _reason -> []
        end

      :not_running ->
        []
    end
  end

  # The answer reaches the task only when the owner key is the key of
  # the owner of the task and the principal holds the scopes.
  #
  @doc false
  @spec deliver(Instance.t(), term(), Principal.t() | nil, String.t(), term()) :: :ok
  def deliver(instance, owner_key, principal, "t." <> rest = out_id, outcome) do
    _ =
      with [task_id, _n] <- String.split(rest, "."),
           {:ok, record} <- fetch_owned(instance, owner_key, task_id),
           true <- scopes_visible?(record, principal) do
        cast_task(instance, task_id, {:answer, out_id, outcome})
      end

    :ok
  end

  # A process of the task sends a notification of the task. The task
  # decides where the message goes; the filter is for a log and the
  # receiving session decides with its own level.
  #
  @doc false
  @spec notify(Instance.t(), String.t(), map(), nil | {:log, atom()}) :: :ok
  def notify(instance, task_id, rpc_notification, filter \\ nil) do
    _ = cast_task(instance, task_id, {:notify, rpc_notification, filter})
    :ok
  end

  # `{:error, :no_task}` when the record is not in the store, the task
  # is terminal, or it does not run.
  #
  @doc false
  @spec client_capabilities(Instance.t(), String.t()) :: {:ok, map()} | error()
  def client_capabilities(instance, task_id) do
    case fetch_config(instance) do
      {:ok, config} ->
        case Records.get(config.opts.task_store, instance, task_id) do
          {:ok, %{status: status}} when status in @terminal ->
            {:error, :no_task}

          {:ok, record} ->
            case Instance.whereis(instance, {:task, task_id}) do
              {:ok, _pid} -> {:ok, record.client_capabilities}
              :not_running -> {:error, :no_task}
            end

          _not_found ->
            {:error, :no_task}
        end

      _not_running ->
        {:error, :unavailable}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  # The task sends the held requests as
  # `{:oz_mcp_stream, stream_id, payload}` and the end of the task as
  # `{:oz_mcp_task_result, task_id, outcome}` — the contract with
  # `OzMcp.Tasks.Result`.
  #
  @doc false
  @spec attach(Instance.t(), term(), String.t(), String.t() | nil, map()) ::
          {:attached, pid()} | {:done, {:ok, term()} | error()}
  def attach(instance, owner_key, task_id, stream_id, origin),
    do: attach(instance, owner_key, task_id, stream_id, origin, @await_attempts)

  defp attach(instance, owner_key, task_id, stream_id, origin, attempts) do
    case fetch_owned(instance, owner_key, task_id) do
      {:ok, %{status: status, result: result}} when status in @terminal ->
        {:done, {:ok, result}}

      {:ok, %{pid: pid}} when is_pid(pid) and attempts > 0 ->
        case call_task(pid, {:attach, self(), stream_id, origin}, @call_timeout) do
          :ok ->
            {:attached, pid}

          {:gone, _reason} ->
            attach(instance, owner_key, task_id, stream_id, origin, attempts - 1)

          error ->
            {:done, error}
        end

      {:ok, _record} ->
        {:done, reconcile_result(instance, owner_key, task_id)}

      error ->
        {:done, error}
    end
  end

  @doc false
  @spec detach(Instance.t(), String.t()) :: :ok
  def detach(instance, task_id) do
    case Instance.whereis(instance, {:task, task_id}) do
      {:ok, pid} ->
        _ = call_task(pid, {:detach, self()}, @call_timeout)
        :ok

      :not_running ->
        :ok
    end
  end

  # A busy or a stopped task process cannot stop the session.
  #
  @doc false
  @spec terminate_session_async(Instance.t(), String.t(), Enumerable.t()) :: :ok | error()
  def terminate_session_async(instance, session_id, task_ids \\ []) do
    with {:ok, _config} <- fetch_config(instance) do
      drop_session(instance, session_id, task_ids)
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  @doc false
  @spec to_task(EtsStore.t()) :: Task.t()
  def to_task(record) do
    %Task{}
    |> Task.task_id(record.task_id)
    |> Task.status(record.status)
    |> Task.status_message(record.status_message)
    |> Task.created_at(to_iso8601(record.created_at))
    |> Task.last_updated_at(to_iso8601(record.last_updated_at))
    |> Task.ttl(record.ttl)
    |> Task.poll_interval(record.poll_interval)
  end

  defp fetch_config(instance) do
    case Instance.config(instance) do
      {:ok, config} -> {:ok, config}
      _not_running -> {:error, :unavailable}
    end
  end

  defp new_record(attrs, opts) do
    now = DateTime.utc_now()

    %EtsStore{
      task_id: Generator.task_id(),
      session_id: attrs.session_id,
      owner_key: owner_key(%{principal: attrs[:principal], session_id: attrs.session_id}),
      seq: System.unique_integer([:monotonic, :positive]),
      status: :working,
      created_at: now,
      last_updated_at: now,
      ttl: resolve_ttl(attrs[:ttl], opts),
      poll_interval: tool_poll_interval(attrs[:poll_interval]) || opts.task_poll_interval_ms,
      progress_token: attrs[:progress_token],
      client_capabilities: attrs[:client_capabilities] || %{},
      principal: attrs[:principal],
      required_scopes: attrs[:required_scopes] || [],
      tool: attrs.tool
    }
  end

  # The hint of the tool: a positive integer only; another shape gives
  # the instance default.
  #
  defp tool_poll_interval(value) when is_integer(value) and value > 0, do: value
  defp tool_poll_interval(_other), do: nil

  # The check and the start are not one step: two creates at the same
  # time can pass the limit by one.
  #
  defp start_task(instance, opts, record, attrs) do
    case reached_limit(instance, opts, record) do
      nil ->
        runner = %{
          #
          # The request goes to the runner only: the record never keeps
          # it, so a record in the store holds no copy of the arguments.
          #
          run: run_fun(instance, record, attrs.request),
          check: check_fun(instance, record.tool, attrs[:output_schema], opts),
          check_results: opts.check_results
        }

        spec = OzMcp.Task.child_spec({instance, record, runner})

        case DynamicSupervisor.start_child(Instance.via(instance, :tasks), spec) do
          {:ok, _pid} ->
            {:ok, to_task(record)}

          # The runner did not start: the process wrote the `failed`
          # record before it ended and the create returns that record.
          #
          :ignore ->
            case Records.get(opts.task_store, instance, record.task_id) do
              {:ok, stored} -> {:ok, to_task(stored)}
              _other -> {:error, :unavailable}
            end

          {:error, _reason} = error ->
            error
        end

      {limit, value, scope} ->
        refuse(instance, limit, value, scope)

      # A failure of the store in a read of the limits is not a limit:
      # the create gives `{:error, :unavailable}`.
      #
      :unavailable ->
        {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp refuse(instance, limit, value, scope) do
    Telemetry.limit(Telemetry.handle(instance), limit, value, scope)
    {:error, {:too_many_tasks, limit}}
  end

  # A task terminal at its creation has no process and no status
  # notification. The active limits do not apply; the record limits do.
  #
  defp settle(instance, opts, record, {status, message, outcome}) do
    case record_limit(instance, opts, record.owner_key) do
      :unavailable ->
        {:error, :unavailable}

      {limit, value, scope} ->
        refuse(instance, limit, value, scope)

      nil ->
        record = %{
          record
          | status: status,
            status_message: message,
            result: outcome,
            expires_at_ms: expires_at_ms(record)
        }

        # A store that does not write the record must not give a task to
        # the client: the client would poll a task that does not exist.
        #
        case Records.put(opts.task_store, instance, record) do
          :ok ->
            if record.expires_at_ms, do: Reaper.rearm(instance)
            {:ok, to_task(record)}

          _error ->
            {:error, :unavailable}
        end
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc false
  @spec ttl_ceiling_ms() :: pos_integer()
  def ttl_ceiling_ms, do: @ttl_ceiling_ms

  @doc false
  @spec expires_at_ms(EtsStore.t()) :: integer() | nil
  def expires_at_ms(record), do: EtsStore.deadline_ms(record)

  @stopped_message "The server stopped the task."
  @crash_message "The task process crashed."
  @runner_crash_message "The task runner crashed."

  @doc false
  @spec failed_record(EtsStore.t(), String.t()) :: EtsStore.t()
  def failed_record(record, message) do
    record = %{
      record
      | status: :failed,
        status_message: message,
        last_updated_at: DateTime.utc_now(),
        pid: nil,
        runner_pid: nil,
        result: {:error, %{code: -32_603, message: message, data: nil}}
    }

    %{record | expires_at_ms: expires_at_ms(record)}
  end

  @doc false
  @spec lost_message(term()) :: String.t()
  def lost_message(:shutdown), do: @stopped_message
  def lost_message({:shutdown, _}), do: @stopped_message
  def lost_message(:lost), do: @stopped_message
  def lost_message(_crash), do: @crash_message

  # The reason can hold the text of an exception: it goes to the log
  # only and the client gets the fixed text.
  #
  @doc false
  @spec runner_crash_message() :: String.t()
  def runner_crash_message, do: @runner_crash_message

  # `Process.alive?/1` raises for a pid that is not local (a shared
  # custom store, or an earlier run). This helper never raises.
  #
  @doc false
  @spec pid_state(pid() | nil) :: :alive | :dead | :remote
  def pid_state(nil), do: :dead
  def pid_state(pid) when node(pid) != node(), do: :remote

  # A pid of an earlier run of this node (same node name, other creation).
  #
  def pid_state(pid) do
    if Process.alive?(pid), do: :alive, else: :dead
  rescue
    ArgumentError -> :dead
  end

  # `nil` when no limit is reached, or `{limit, value, scope}` for the
  # limit that the create refused. The active limits come first.
  #
  defp reached_limit(instance, opts, record) do
    case session_limit?(instance, opts, record.session_id) do
      :unavailable ->
        :unavailable

      true ->
        {:max_tasks_per_session, opts.max_tasks_per_session, :session}

      false ->
        case principal_limit?(instance, opts, record.owner_key) do
          :unavailable ->
            :unavailable

          true ->
            {:max_tasks_per_principal, opts.max_tasks_per_principal, :principal}

          false ->
            record_limit(instance, opts, record.owner_key)
        end
    end
  end

  # Active and terminal records count. The record limit comes before the
  # byte limit, so the report is stable.
  #
  defp record_limit(instance, opts, owner_key) do
    case Records.owner_usage(opts.task_store, instance, owner_key) do
      {records, bytes} when is_integer(records) and is_integer(bytes) ->
        scope = if match?({:session, _}, owner_key), do: :session, else: :principal

        cond do
          over?(records, opts.max_task_records_per_owner) ->
            {:max_task_records_per_owner, opts.max_task_records_per_owner, scope}

          over?(bytes, opts.max_task_bytes_per_owner) ->
            {:max_task_bytes_per_owner, opts.max_task_bytes_per_owner, scope}

          true ->
            nil
        end

      _other ->
        :unavailable
    end
  end

  defp over?(_used, nil), do: false
  defp over?(used, max), do: used >= max

  defp session_limit?(_instance, %{max_tasks_per_session: nil}, _session_id), do: false

  defp session_limit?(instance, opts, session_id) do
    case Records.count_active(opts.task_store, instance, {:session, session_id}) do
      count when is_integer(count) -> count >= opts.max_tasks_per_session
      _other -> :unavailable
    end
  end

  defp principal_limit?(_instance, %{max_tasks_per_principal: nil}, _owner_key), do: false
  defp principal_limit?(_instance, _opts, {:session, _session_id}), do: false

  defp principal_limit?(instance, opts, owner_key) do
    case Records.count_active(opts.task_store, instance, {:owner, owner_key}) do
      count when is_integer(count) -> count >= opts.max_tasks_per_principal
      _other -> :unavailable
    end
  end

  # The tool runs through the callback of the task: ONE callback, the
  # `call(ctx, params)` of the behaviour. The principal is the snapshot
  # of the request that created the task.
  #
  defp run_fun(instance, record, request) do
    {tool_module, _tool_name} = record.tool

    ctx = %{
      instance: instance,
      server: Instance.server_module(instance),
      session_id: record.session_id,
      request_id: nil,
      progress_token: record.progress_token,
      task_id: record.task_id,
      client_capabilities: record.client_capabilities || %{},
      principal: record.principal
    }

    fn -> tool_module.call(ctx, request) end
  end

  # The check runs in the guard of the runner, with the contract of the
  # `:check` option of `Invoke.run/3`. A schema that does not compile is
  # a server defect: the check raises and the guard gives -32603.
  #
  defp check_fun(_instance, _tool, _schema, %{check_output_schemas: false}), do: nil

  defp check_fun(instance, {tool_module, tool_name}, schema, _opts) do
    server = Instance.server_module(instance)

    fn built ->
      case Output.fetch_root(server, tool_module, tool_name, schema) do
        {:ok, root} -> Output.check(root, built)
        {:error, :invalid_schema} -> raise "the output schema of the tool does not compile"
      end
    end
  end

  # Nothing is removed: the caller decides what to do with an expired
  # record.
  #
  defp read_owned(instance, owner_key, task_id) do
    with {:ok, config} <- fetch_config(instance) do
      case Records.get(config.opts.task_store, instance, task_id) do
        {:ok, %{owner_key: ^owner_key} = record} ->
          if EtsStore.expired?(record), do: {:expired, record}, else: {:ok, record}

        _other ->
          {:error, :no_task}
      end
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  # An expired record is removed when it is read: a live process is told
  # to stop.
  #
  defp fetch_owned(instance, owner_key, task_id) do
    case read_owned(instance, owner_key, task_id) do
      {:expired, record} ->
        with {:ok, config} <- fetch_config(instance) do
          remove_expired(instance, config.opts, record)
          {:error, :expired}
        end

      other ->
        other
    end
  end

  # Only the process of the task, or the reaper of its node, writes a
  # record of another node.
  #
  defp remove_expired(instance, opts, %{pid: pid} = record) do
    case pid_state(pid) do
      :dead ->
        _ = Records.delete(opts.task_store, instance, record)
        :ok

      _alive_or_remote ->
        :gen_statem.cast(pid, :expire)
    end
  end

  defp drop_session(instance, session_id, task_ids) do
    {:ok, config} = Instance.config(instance)
    store = config.opts.task_store

    owned = session_records(instance, store, {:session, session_id}, 0, [])

    tracked =
      Enum.flat_map(task_ids, fn task_id ->
        case Records.get(store, instance, task_id) do
          {:ok, %{session_id: ^session_id, pid: pid} = record} when is_pid(pid) -> [record]
          _other -> []
        end
      end)

    (owned ++ tracked)
    |> Enum.uniq_by(& &1.task_id)
    |> Enum.each(fn
      %{pid: pid} when is_pid(pid) -> :gen_statem.cast(pid, :drop)
      record -> Records.delete(store, instance, record)
    end)
  end

  defp session_records(instance, store, owner_key, after_seq, pages) do
    case Records.page(store, instance, owner_key, after_seq, @page_batch) do
      {records, nil} -> [records | pages] |> Enum.reverse() |> Enum.concat()
      {records, next} -> session_records(instance, store, owner_key, next, [records | pages])
    end
  end

  defp cast_task(instance, task_id, message) do
    case Instance.whereis(instance, {:task, task_id}) do
      {:ok, pid} -> :gen_statem.cast(pid, message)
      :not_running -> with {:ok, _config} <- fetch_config(instance), do: :ok
    end
  end

  defp call_task(pid, message, timeout) do
    :gen_statem.call(pid, message, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:gone, reason}
  end

  defp parse_cursor(nil), do: {:ok, 0}

  defp parse_cursor(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {seq, ""} when seq >= 0 -> {:ok, seq}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp parse_cursor(_cursor), do: {:error, :invalid_cursor}

  # TTL resolution: the ttl that the client asked, else
  # task_default_ttl_ms, else task_max_ttl_ms, each capped.
  #
  defp resolve_ttl(nil, opts),
    do: cap_ttl(opts.task_default_ttl_ms || opts.task_max_ttl_ms, opts)

  # A ttl of 0 is a refusal of the wire only: this module is not a wire
  # layer.
  #
  defp resolve_ttl(requested, opts) when is_integer(requested) and requested >= 0,
    do: cap_ttl(requested, opts)

  defp cap_ttl(nil, _opts), do: nil

  defp cap_ttl(ttl, opts) do
    ttl
    |> min(opts.task_max_ttl_ms || @ttl_ceiling_ms)
    |> min(@ttl_ceiling_ms)
  end

  defp to_iso8601(datetime) do
    datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
