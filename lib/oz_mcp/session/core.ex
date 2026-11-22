#
# The state of a session that the pure modules own. A pure function
# never calls `self/0`, a generator or the clock: the struct holds
# them.
#
defmodule OzMcp.Session.Core do
  @moduledoc false

  alias OzMcp.Instance
  alias OzMcp.LogLevel

  alias OzMcp.Session.{
    Effect,
    EventLog,
    LogRate,
    Outbound,
    Persistence,
    Replay,
    Requests,
    Roots,
    Route,
    Subscriptions,
    View
  }

  alias OzMcp.Session.Streams.Get
  alias OzMcp.Session.Streams.Post
  alias OzMcp.Utils.Generator

  @view_fields [:log_level, :client_capabilities, :client_info, :protocol_version]

  defstruct [
    :instance,
    :id,
    :view,
    :opts,
    :saved,
    :pid,
    ids: Generator,
    clock: System,
    log_bucket: nil,
    log_dropped: 0,
    retired: false,
    subscriptions: MapSet.new(),
    subscription_scopes: %{},
    requests: %{},
    outbound: %{},
    streams: %{},
    get_streams: [],
    closed_gets: [],
    log: %EventLog{},
    progress: {%{}, :queue.new()},
    tasks: MapSet.new(),
    roots: %{running: nil, again: false, ctx: nil}
  ]

  @type t :: %__MODULE__{}

  # The idle timer: a session that is not idle (`idle?/1`) cancels it.
  #
  @spec idle_timer(t()) ::
          {{:timeout, :idle}, :cancel} | {{:timeout, :idle}, non_neg_integer(), :idle}
  def idle_timer(%__MODULE__{opts: opts} = core) do
    if idle?(core),
      do: {{:timeout, :idle}, opts.session_timeout_ms, :idle},
      else: {{:timeout, :idle}, :cancel}
  end

  # True when no stream, request, server request or task holds the session.
  #
  @spec idle?(t()) :: boolean()
  def idle?(%__MODULE__{} = core) do
    core.streams == %{} and core.get_streams == [] and core.requests == %{} and
      core.outbound == %{} and not tracked_tasks?(core)
  end

  defp tracked_tasks?(%__MODULE__{opts: %{tasks_follow_session: true}, tasks: tasks}),
    do: MapSet.size(tasks) > 0

  defp tracked_tasks?(_core), do: false

  # Changes the public view. The shell writes the Registry only on a
  # change.
  #
  @spec put_view(t(), keyword()) :: {t(), [Effect.t()]}
  def put_view(core, changes) do
    view = struct!(core.view, changes)

    if view == core.view,
      do: {core, []},
      else: {%{core | view: view}, [{:view, view}]}
  end

  # The core of a new session.
  #
  @spec new(Instance.t(), map(), map(), View.t()) :: t()
  def new(instance, attrs, opts, view) do
    %__MODULE__{
      instance: instance,
      id: attrs.session_id,
      view: view,
      opts: opts,
      pid: view.pid,
      subscriptions: MapSet.new(Map.get(attrs, :subscriptions, [])),
      subscription_scopes: Map.get(attrs, :subscription_scopes, %{}),
      log:
        EventLog.new(
          opts.sse_event_log_size,
          opts.sse_event_log_bytes,
          opts.sse_event_log_session_bytes,
          opts.sse_event_log_max_streams
        )
    }
  end

  @stamp_every_ms 1_000

  # The effects of one event of the session.
  #
  @spec handle(term(), atom(), t()) :: {t(), [Effect.t()]}
  def handle(event, state, core) do
    {core, effects} = step(event, state, core)

    if active?(event, effects), do: stamp(core, effects), else: {core, effects}
  end

  defp active?(_event, effects), do: :idle_check in effects

  defp stamp(%__MODULE__{view: %View{}} = core, effects) do
    now = core.clock.monotonic_time(:millisecond)
    last = core.view.last_active_ms

    if is_nil(last) or now - last >= @stamp_every_ms do
      {core, view} = put_view(core, last_active_ms: now)
      {core, effects ++ view}
    else
      {core, effects}
    end
  end

  defp stamp(core, effects), do: {core, effects}

  defp step({:call, {:terminate, _reason}}, :closing, core),
    do: {core, [{:reply, :ok}]}

  defp step({{:timeout, :init}, :init}, :initializing, core),
    do: {core, [{:stop, {:shutdown, :init_timeout}}]}

  defp step({:call, :initialized}, :initializing, core) do
    {core, view} = put_view(core, initialized: true)
    {core, topics} = Subscriptions.topics(core)
    {core, save} = Persistence.save(core)

    {core,
     view ++
       topics ++
       save ++
       [
         {:next_state, :ready},
         {:reply, :ok},
         {:timeout, {:timeout, :init}, :cancel, nil},
         :idle_check
       ]}
  end

  defp step({:call, :initialized}, :ready, core), do: {core, [{:reply, :ok}]}

  defp step({:cast, {:track_task, task_id, pid}}, _state, core) do
    {%{core | tasks: MapSet.put(core.tasks, task_id)},
     [{:monitor, pid, {:task, task_id}}, :idle_check]}
  end

  defp step({:cast, {:untrack_task, task_id}}, _state, core) do
    {%{core | tasks: MapSet.delete(core.tasks, task_id)},
     [{:demonitor, {:task, task_id}}, :idle_check]}
  end

  defp step({:cast, {:touch, _granted}}, :closing, core), do: {core, []}

  defp step({:cast, {:touch, granted}}, _state, core) do
    {core, effects} = Subscriptions.drop_lost_scopes(core, granted)
    {core, effects ++ [:idle_check]}
  end

  defp step({{:timeout, :idle}, :idle}, :ready, core),
    do: {core, [{:stop, {:shutdown, :idle}}]}

  defp step({:call, {:update_view, changes}}, _state, core) do
    changes = Keyword.take(changes, @view_fields)
    {core, view} = put_view(core, changes)
    {core, save} = Persistence.save(core)
    {core, view ++ save ++ [{:reply, :ok}]}
  end

  # A duplicate id is a defect of the client: refused with no spawn.
  #
  defp step({:call, {:open_request, request_id, owner, stream, stream_owner}}, state, core)
       when state != :closing and (is_binary(request_id) or is_integer(request_id)) and
              (is_nil(stream) or elem(stream, 1) in [:sse, :sink]) and is_pid(stream_owner) do
    case Requests.register(core, request_id, owner) do
      {:error, :duplicate, effects} ->
        {core, effects ++ [{:reply, {:error, :duplicate}}]}

      {:ok, core, effects} ->
        {core, monitor} = open_stream_entry(core, request_id, stream_owner, stream)
        {core, effects ++ monitor ++ [{:reply, :ok}]}
    end
  end

  defp step({:call, {:open_request, request_id, owner, stream}}, state, core)
       when state != :closing,
       do: step({:call, {:open_request, request_id, owner, stream, owner}}, state, core)

  defp step({:call, {:attach_runner, request_id, runner}}, _state, core)
       when is_pid(runner),
       do: Requests.attach_runner(core, request_id, runner)

  defp step({:call, {:stream_owner, request_id}}, _state, core),
    do: Requests.owner(core, request_id)

  # Any other request gets `:gone` and keeps its entry, so an old copy of
  # a stream struct frees nothing.
  #
  defp step({:call, {:close_request, request_id, stream_id, final}}, _state, core) do
    case Map.get(core.requests, request_id) do
      %{stream_id: ^stream_id} ->
        {core, effects} = close_stream_of(core, request_id, stream_id, final)
        {core, free} = Requests.finish(core, request_id)
        {core, effects ++ free}

      _other_or_gone ->
        {core, [{:reply, :gone}]}
    end
  end

  defp step({:call, {:promote_stream, request_id, stream_id}}, _state, core) do
    case Map.get(core.requests, request_id) do
      %{stream_id: ^stream_id} -> Post.promote(core, stream_id)
      _other_or_gone -> {core, [{:reply, :gone}]}
    end
  end

  defp step({:call, {:hand_off_stream, request_id, stream_id}}, _state, core) do
    case Map.get(core.requests, request_id) do
      %{stream_id: ^stream_id} -> Post.hand_off(core, stream_id)
      _other_or_gone -> {core, [{:reply, :gone}]}
    end
  end

  defp step({:cast, {:end_request, request_id}}, _state, core) do
    {core, detach} =
      case Map.get(core.requests, request_id) do
        %{stream_id: stream_id} when is_binary(stream_id) ->
          core = Requests.clear_stream(core, request_id)
          Post.detach(core, stream_id)

        _no_stream_or_gone ->
          {core, []}
      end

    {core, free} = Requests.finish(core, request_id)
    {core, detach ++ free}
  end

  # A cancel is delivered even before the callback process starts: the
  # owner is known from the registration.
  #
  defp step({:cast, {:cancel, request_id, reason}}, _state, core),
    do: Requests.cancel(core, request_id, reason)

  defp step({:call, {:request_client, _waiter, _route, _method, _params}}, :closing, core),
    do: {core, [{:reply, {:error, :session_terminated}}]}

  defp step({:call, {:request_client, waiter, route, method, params}}, _state, core)
       when is_binary(method) and is_pid(waiter),
       do: Outbound.request(core, waiter, route, method, params)

  defp step({:cast, {:deliver_outbound, out_id, outcome}}, _state, core),
    do: Outbound.deliver(core, out_id, outcome)

  defp step({:call, {:cancel_outbound, out_id}}, _state, core),
    do: Outbound.cancel(core, out_id, "request timed out")

  defp step({:call, {:abandon_waiter, waiter, reason}}, _state, core)
       when is_pid(waiter) do
    {core, effects} = Outbound.abandon(core, &(&1.waiter == waiter), reason)
    {core, effects ++ [:idle_check, {:reply, :ok}]}
  end

  defp step({:call, {:open_stream, kind, pid, last_event_id}}, state, core)
       when state != :closing do
    target = if kind == :get, do: Replay.target(last_event_id), else: :fresh

    case target do
      {:post, stream_id, seq} ->
        ended? = not Map.has_key?(core.streams, stream_id)
        Post.resume(core, pid, stream_id, seq, ended?)

      _get ->
        Get.open(core, kind, target, pid)
    end
  end

  defp step({:call, {:close_stream, pid}}, _state, core), do: Get.close(core, pid)

  defp step({:call, {:detach_resume, stream_id, pid}}, _state, core) do
    {core, effects} = Post.detach_resume(core, stream_id, pid)
    {core, effects ++ [{:reply, :ok}]}
  end

  # The debug line holds neither the token nor the value.
  #
  defp step({:cast, {:progress, target, token, value, encoded}}, state, core) do
    case Requests.check_progress(core, target, token, value) do
      {:ok, core} ->
        step({:cast, {:emit, target, encoded}}, state, core)

      {:drop, core} ->
        {core, [{:log, :debug, "a progress value that does not increase was dropped"}]}
    end
  end

  # A message over the log rate is dropped and its count joins the
  # report of the window.
  #
  defp step({:cast, {:log, target, encoded}}, state, core) do
    case LogRate.admit(core) do
      {:ok, core, []} -> step({:cast, {:emit, target, encoded}}, state, core)
      {:drop, core, effects} -> {core, effects}
    end
  end

  # No guard on the state: a report also runs in `:closing`.
  #
  defp step({{:timeout, :log_drops}, :report}, _state, core), do: LogRate.report(core)

  defp step({:cast, {:emit, {:request, request_id}, message}}, _state, core),
    do: Post.emit_request(core, request_id, message)

  defp step({:cast, {:emit, {:request_or_session, request_id}, message}}, _state, core),
    do: Route.request_or_session(core, request_id, message)

  defp step({:cast, {:emit, {:stream, stream_id}, message}}, _state, core),
    do: Post.emit(core, stream_id, message)

  defp step({:cast, {:emit, :session, message}}, _state, core), do: Get.emit(core, message)

  # A refused message uses no token of the bucket.
  #
  defp step(
         {:info, {:oz_mcp_broadcast, {:session_event, {:log, _level} = filter, message}}},
         state,
         core
       ) do
    if wanted?(core, filter),
      do: step({:cast, {:log, :session, message}}, state, core),
      else: {core, []}
  end

  defp step({:info, {:oz_mcp_broadcast, {:session_event, filter, message}}}, _state, core) do
    if wanted?(core, filter), do: Get.emit(core, message), else: {core, []}
  end

  defp step({:call, {:subscribe, uri, required}}, _state, core) when is_list(required),
    do: Subscriptions.subscribe(core, uri, required)

  defp step({:call, {:unsubscribe, uri}}, _state, core),
    do: Subscriptions.unsubscribe(core, uri)

  defp step({:info, {:kill_callback, runner}}, _state, core),
    do: {core, [{:exit, runner, :kill}]}

  # A tag that fired is gone from the maps.
  #
  defp step({:down, :roots, _pid}, _state, core), do: Roots.down(core)

  defp step({:down, {:get, stream_id}, _pid}, _state, core), do: Get.down(core, stream_id)

  # When another process still owns the request, the stream becomes a
  # hand-off and the callback goes on.
  #
  defp step({:down, {:owner, stream_id}, pid}, _state, core) do
    if handed_over?(core, stream_id, pid) do
      Post.connection_down(core, stream_id)
    else
      {core, effects} = Post.owner_down(core, stream_id)
      {core, effects ++ [:idle_check]}
    end
  end

  defp step({:down, {:resumer, stream_id}, _pid}, _state, core),
    do: Post.resumer_down(core, stream_id)

  # The entry goes first, so the notices of its requests go to the GET
  # stream. A stream with another owner goes too: nobody would free it.
  #
  defp step({:down, {:request, request_id}, pid}, _state, core) do
    {core, result, stream_id} = Requests.pop_owner(core, request_id)
    {core, detach} = detach_stream(core, stream_id, pid)

    case result do
      nil ->
        {core, detach}

      :no_runner ->
        {core, detach ++ [:idle_check]}

      runner ->
        {core, abandon} = Outbound.abandon(core, &(&1.waiter == runner), "the request ended")
        {core, detach ++ Requests.runner_stop_effects(core, runner, abandon)}
    end
  end

  defp step({:down, {:outbound, _out_id}, pid}, _state, core),
    do: Outbound.waiter_down(core, pid)

  # A task process that died without `untrack_task` frees its id, so
  # the idle timer runs again.
  #
  defp step({:down, {:task, task_id}, _pid}, _state, core),
    do: {%{core | tasks: MapSet.delete(core.tasks, task_id)}, [:idle_check]}

  defp step({:call, {:terminate, reason}}, state, core) when state != :closing do
    {core, retire} = Persistence.retire(core)

    {core,
     retire ++
       [{:next_state, :closing}, {:reply, :ok}, {:next_event, :internal, {:close, reason}}]}
  end

  defp step({:internal, {:close, reason}}, :closing, core),
    do: {core, [{:stop, {:shutdown, reason}}]}

  defp step({:cast, {:roots_changed, ctx}}, _state, core), do: Roots.changed(core, ctx)

  # A late timer of an ended run does nothing.
  #
  defp step({{:timeout, :roots}, pid}, _state, core), do: Roots.deadline(core, pid)

  # A resume cancels the timer, so this check is only a guard.
  #
  defp step({{:timeout, {:log, stream_id}}, :drop_log}, _state, core),
    do: Get.window_over(core, stream_id)

  defp step({:call, :evict}, state, core) when state != :closing do
    if idle?(core),
      do: step({:call, {:terminate, :evicted}}, state, core),
      else: {core, [{:reply, {:error, :busy}}]}
  end

  # In `:closing` the session is gone for the caller. Any other call is a
  # defect of the caller: an error at once.
  #
  defp step({:call, message}, :closing, core) do
    {core,
     [
       {:log, :debug,
        "session call #{inspect(call_tag(message))} refused: the session is closing"},
       {:reply, {:error, :no_session}}
     ]}
  end

  defp step({:call, message}, state, core) do
    {core,
     [
       {:log, :warning,
        "session call #{inspect(call_tag(message))} has no clause in #{inspect(state)}"},
       {:reply, {:error, :badarg}}
     ]}
  end

  defp step(_event, _state, core), do: {core, []}

  # The effects of the end of the session.
  #
  # The session leaves the Registry first, so a lookup after this point
  # gives no session. The snapshot goes away unless the session crashed.
  #
  @spec terminate(t(), term()) :: {t(), [Effect.t()]}
  def terminate(core, reason) do
    {core, registry} =
      if Persistence.crash?(reason),
        do: {core, Persistence.unregister(core)},
        else: Persistence.retire(core)

    {core, get} = Get.end_all(core)
    {core, post} = Post.end_all(core)
    {core, requests} = Requests.end_all(core)
    {core, outbound} = Outbound.end_all(core)
    {core, roots} = Roots.stop(core)

    {core,
     [{:span_stop, %{reason: stop_reason(reason)}}] ++
       registry ++ get ++ post ++ requests ++ outbound ++ roots ++ end_tasks(core)}
  end

  defp open_stream_entry(core, _request_id, _owner, nil), do: {core, []}

  # The owner of the stream can be another process than the owner of the
  # request.
  #
  defp open_stream_entry(core, request_id, stream_owner, {stream_id, mode}) do
    request = Map.fetch!(core.requests, request_id)
    core = put_in(core.requests[request_id], %{request | stream_id: stream_id})
    Post.new(core, stream_id, stream_owner, request_id, mode)
  end

  # True when another process still owns the request: the stream stays
  # for its events.
  #
  defp handed_over?(core, stream_id, pid) do
    case Map.get(core.streams, stream_id) do
      %{request_id: request_id} ->
        case Map.get(core.requests, request_id) do
          %{owner: owner} -> owner != pid
          _request_gone -> false
        end

      _no_entry ->
        false
    end
  end

  # Another owner (or none) leaves an entry nobody frees, so it goes.
  #
  defp detach_stream(core, stream_id, pid) when is_binary(stream_id) do
    case Map.get(core.streams, stream_id) do
      %{owner: owner} when owner != pid -> Post.detach(core, stream_id)
      _same_owner_or_gone -> {core, []}
    end
  end

  defp detach_stream(core, _stream_id, _pid), do: {core, []}

  # A sink writes the response itself, so the session only forgets the
  # entry.
  #
  defp close_stream_of(core, request_id, stream_id, {:response, response, started?}),
    do: Post.finish(core, request_id, stream_id, response, started?)

  defp close_stream_of(core, request_id, stream_id, :detach) do
    core = Requests.clear_stream(core, request_id)
    {core, effects} = Post.detach(core, stream_id)
    {core, effects ++ [{:reply, :ok}]}
  end

  # A bare `:shutdown` has no clause: the session does not trap exits.
  #
  defp stop_reason({:shutdown, :idle}), do: :idle
  defp stop_reason({:shutdown, :init_timeout}), do: :init_timeout
  defp stop_reason({:shutdown, :terminated}), do: :terminated
  defp stop_reason({:shutdown, :evicted}), do: :evicted
  defp stop_reason({:shutdown, _other}), do: :closed
  defp stop_reason(:normal), do: :normal
  defp stop_reason(_crash), do: :crash

  # With `tasks_follow_session` the tasks that run stop with the session.
  #
  defp end_tasks(%__MODULE__{opts: %{tasks_follow_session: true}, tasks: tasks}),
    do: [{:end_tasks, tasks}]

  defp end_tasks(_core), do: []

  # Only the tag is logged: the rest can hold client data.
  #
  defp call_tag(message) when is_atom(message), do: message

  defp call_tag(message)
       when is_tuple(message) and tuple_size(message) > 0 and is_atom(elem(message, 0)),
       do: elem(message, 0)

  defp call_tag(_message), do: :unknown

  defp wanted?(_core, nil), do: true

  defp wanted?(core, {:log, level}), do: LogLevel.wanted?(core.view.log_level, level)
end
