#
# The process of one session: a shell that holds the `gen_statem`
# callbacks, the monitors and the telemetry. The rules live in
# `OzMcp.Session.Core`, `OzMcp.Session.Requests`,
# `OzMcp.Session.Outbound`, `OzMcp.Session.Route`,
# `OzMcp.Session.Streams`, `OzMcp.Session.Streams.Post`,
# `OzMcp.Session.Streams.Get`, `OzMcp.Session.Roots`,
# `OzMcp.Session.Subscriptions`, `OzMcp.Session.Persistence` and
# `OzMcp.Session.Effect`; the effects run in `OzMcp.Session.Effects`.
#
defmodule OzMcp.Session do
  @moduledoc false

  @behaviour :gen_statem

  alias OzMcp.Instance

  alias OzMcp.Session.{Core, Effects, Persistence, Subscriptions, View}
  alias OzMcp.Telemetry

  defstruct [
    :core,
    :telemetry,
    :span,
    refs: %{},
    monitors: %{}
  ]

  @type t :: %__MODULE__{}

  @type sent :: :ok | {:error, :unavailable}

  @call_timeout 5_000

  @doc false
  def child_spec({instance, attrs}) do
    %{
      id: {__MODULE__, attrs.session_id},
      start: {__MODULE__, :start_link, [{instance, attrs}]},
      restart: :temporary
    }
  end

  @doc false
  def start_link({instance, attrs}) do
    #
    # The pid is not known yet: init/1 puts the full view.
    #
    view = View.new(nil, attrs, System.monotonic_time(:millisecond))
    name = {:via, Registry, {Instance.names(instance), {:session, attrs.session_id}, view}}
    :gen_statem.start_link(name, __MODULE__, {instance, attrs}, [])
  end

  # Starts a session under the session supervisor of the instance.
  #
  @spec start(Instance.t(), map()) :: {:ok, pid()} | {:error, term()}
  def start(instance, attrs) do
    DynamicSupervisor.start_child(
      Instance.via(instance, :sessions),
      child_spec({instance, attrs})
    )
  end

  # The client sent `notifications/initialized`.
  #
  @spec initialized(Instance.t(), String.t()) ::
          :ok | {:error, :no_session | :unavailable | :timeout | :badarg}
  def initialized(instance, id), do: call(instance, id, :initialized)

  # A request of the client starts the idle timer again.
  #
  @spec touch(Instance.t(), String.t()) :: sent()
  def touch(instance, id), do: touch(instance, id, nil)

  # A list of granted scopes ends the subscriptions that it does not cover.
  #
  @doc false
  @spec touch(Instance.t(), String.t(), [String.t()] | nil) :: sent()
  def touch(instance, id, granted), do: cast(instance, id, {:touch, granted})

  # Changes fields of the public view.
  #
  @spec update_view(Instance.t(), String.t(), keyword()) ::
          :ok | {:error, :no_session | :unavailable | :timeout | :badarg}
  def update_view(instance, id, changes), do: call(instance, id, {:update_view, changes})

  # Opens a stream of the client: `:get` or `:stdio`. The idle timer does
  # not run while one is open.
  #
  @spec open_stream(Instance.t(), String.t(), :get | :stdio, pid(), String.t() | nil) ::
          {:ok, map()}
          | {:error,
             :too_many_streams | :no_session | :unavailable | :timeout | :no_stream | :badarg}
  def open_stream(instance, id, kind, pid, last_event_id) when kind in [:get, :stdio],
    do: call(instance, id, {:open_stream, kind, pid, last_event_id})

  # A GET stream is closed: with no other stream, the idle timer starts again.
  #
  @spec close_stream(Instance.t(), String.t(), pid()) ::
          :ok | {:error, :no_session | :unavailable | :timeout | :badarg}
  def close_stream(instance, id, pid), do: call(instance, id, {:close_stream, pid})

  # A resumer of a POST stream is done: the stream can be resumed again.
  #
  @spec detach_resume(Instance.t(), String.t(), String.t(), pid()) ::
          :ok | {:error, :no_session | :unavailable | :timeout | :badarg}
  def detach_resume(instance, id, stream_id, pid),
    do: call(instance, id, {:detach_resume, stream_id, pid})

  @typedoc """
  The last step of the stream of a request: the response of an HTTP request,
  or the detach of a sink stream.
  """
  @type final :: {:response, iodata(), boolean()} | :detach

  # Ends the stream of a request, numbers the response and frees the id.
  #
  @spec close_request(Instance.t(), String.t(), String.t() | integer(), String.t(), final()) ::
          {:sse, String.t()}
          | :plain
          | :gone
          | :ok
          | {:error, :no_session | :unavailable | :timeout | :badarg}
  def close_request(instance, id, request_id, stream_id, final),
    do: call(instance, id, {:close_request, request_id, stream_id, final})

  # Sends a message (encoded JSON text) to a stream.
  #
  @spec emit(
          Instance.t(),
          String.t(),
          {:request | :request_or_session, String.t() | integer() | nil}
          | {:stream, String.t()}
          | :session,
          iodata()
        ) :: sent()
  def emit(instance, id, target, message), do: cast(instance, id, {:emit, target, message})

  # Sends a progress report; the session checks that the value increases.
  #
  @spec emit_progress(
          Instance.t(),
          String.t(),
          {:request_or_session, String.t() | integer() | nil} | :session,
          term(),
          term(),
          iodata()
        ) :: sent()
  def emit_progress(instance, id, target, token, value, message),
    do: cast(instance, id, {:progress, target, token, value, message})

  # Sends a log notification. The session drops a message over
  # `max_log_rate` and the return is still `:ok`.
  #
  @spec emit_log(
          Instance.t(),
          String.t(),
          {:request | :request_or_session, String.t() | integer() | nil}
          | {:stream, String.t()}
          | :session,
          iodata()
        ) :: sent()
  def emit_log(instance, id, target, message), do: cast(instance, id, {:log, target, message})

  # Subscribes the session to a resource. See `OzMcp.Session.Subscriptions`.
  #
  @spec subscribe(Instance.t(), String.t(), String.t()) ::
          :ok
          | {:error, :too_many_subscriptions | :no_session | :unavailable | :timeout | :badarg}
  def subscribe(instance, id, uri), do: subscribe(instance, id, uri, [])

  @spec subscribe(Instance.t(), String.t(), String.t(), [String.t()]) ::
          :ok
          | {:error, :too_many_subscriptions | :no_session | :unavailable | :timeout | :badarg}
  def subscribe(instance, id, uri, required), do: call(instance, id, {:subscribe, uri, required})

  # Removes the subscription of the session to a resource.
  #
  @spec unsubscribe(Instance.t(), String.t(), String.t()) ::
          :ok | {:error, :no_session | :unavailable | :timeout | :badarg}
  def unsubscribe(instance, id, uri), do: call(instance, id, {:unsubscribe, uri})

  # Ends the session; the answer comes when the process is down.
  #
  @spec close(Instance.t(), String.t(), term()) ::
          :ok | {:error, :no_session | :unavailable | :timeout | :badarg}
  def close(instance, id, reason \\ :terminated),
    do: end_with(instance, id, {:terminate, reason})

  # Ends the session if it is idle; `{:error, :busy}` when it holds work.
  #
  @spec evict(Instance.t(), String.t()) ::
          :ok | {:error, :busy | :no_session | :unavailable | :timeout | :badarg}
  def evict(instance, id), do: end_with(instance, id, :evict)

  defp end_with(instance, id, message) do
    case Instance.whereis(instance, {:session, id}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        case call(instance, id, message) do
          :ok -> await_down(ref)
          error -> demonitor(ref, error)
        end

      :not_running ->
        call(instance, id, message)
    end
  end

  defp await_down(ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      @call_timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end

  defp demonitor(ref, result) do
    Process.demonitor(ref, [:flush])
    result
  end

  # Registers a request and, when `stream` is not `nil`, its stream entry.
  # `stream_owner: pid` names the process that owns the stream.
  #
  @spec open_request(
          Instance.t(),
          String.t(),
          String.t() | integer(),
          pid(),
          nil | {String.t(), :sse | :sink}
        ) :: :ok | {:error, :duplicate | :no_session | :unavailable | :timeout | :badarg}
  def open_request(instance, id, request_id, owner, stream),
    do: open_request(instance, id, request_id, owner, stream, [])

  @spec open_request(
          Instance.t(),
          String.t(),
          String.t() | integer(),
          pid(),
          nil | {String.t(), :sse | :sink},
          keyword()
        ) :: :ok | {:error, :duplicate | :no_session | :unavailable | :timeout | :badarg}
  def open_request(instance, id, request_id, owner, stream, opts) do
    stream_owner = Keyword.get(opts, :stream_owner, owner)
    call(instance, id, {:open_request, request_id, owner, stream, stream_owner})
  end

  # The stream of a request starts: the caller sends the head and the
  # priming event after this call.
  #
  @spec promote_stream(Instance.t(), String.t(), String.t() | integer(), String.t()) ::
          :ok | :gone | {:error, :no_session | :unavailable | :timeout | :badarg}
  def promote_stream(instance, id, request_id, stream_id),
    do: call(instance, id, {:promote_stream, request_id, stream_id})

  # The stream loses its live owner: the connection ends while the callback
  # goes on and the later events go to the log and to a resumer.
  #
  @spec hand_off_stream(Instance.t(), String.t(), String.t() | integer(), String.t()) ::
          :ok | :gone | {:error, :no_session | :unavailable | :timeout | :badarg}
  def hand_off_stream(instance, id, request_id, stream_id),
    do: call(instance, id, {:hand_off_stream, request_id, stream_id})

  # The process that owns the stream of a request, with the id of the stream.
  #
  @spec stream_owner(Instance.t(), String.t(), String.t() | integer()) ::
          {:ok, {pid() | nil, String.t()}} | :none
  def stream_owner(instance, id, request_id) do
    case call(instance, id, {:stream_owner, request_id}) do
      {:ok, _owner} = found -> found
      _none_or_error -> :none
    end
  end

  # Names the process that runs the callback of a registered request.
  #
  @spec attach_runner(Instance.t(), String.t(), String.t() | integer(), pid()) ::
          :ok | {:error, :no_request | :no_session | :unavailable | :timeout | :badarg}
  def attach_runner(instance, id, request_id, runner),
    do: call(instance, id, {:attach_runner, request_id, runner})

  # A request is done: its id is free again. A cast.
  #
  @spec end_request(Instance.t(), String.t(), String.t() | integer()) :: sent()
  def end_request(instance, id, request_id), do: cast(instance, id, {:end_request, request_id})

  # Cancels a registered request: the session sends
  # `{:oz_mcp_cancel, request_id, reason}` to its owner.
  #
  @spec cancel(Instance.t(), String.t(), String.t() | integer(), term()) :: sent()
  def cancel(instance, id, request_id, reason),
    do: cast(instance, id, {:cancel, request_id, reason})

  # Stores a request to the client and routes its first message.
  #
  @spec request_client(
          Instance.t(),
          String.t(),
          {:request, String.t() | integer() | nil},
          pid(),
          String.t(),
          map() | nil
        ) ::
          {:ok, String.t(), pid()}
          | {:error,
             :session_terminated
             | :no_session
             | :unavailable
             | :timeout
             | :not_encodable
             | :badarg}
  def request_client(instance, id, route, waiter, method, params),
    do: call(instance, id, {:request_client, waiter, route, method, params})

  # Hands the answer of the client to the process that waits for it.
  #
  @spec deliver_outbound(Instance.t(), String.t(), String.t(), {:ok, map()} | {:error, term()}) ::
          sent()
  def deliver_outbound(instance, id, out_id, outcome),
    do: cast(instance, id, {:deliver_outbound, out_id, outcome})

  # Cancels a request to the client whose wait ended.
  #
  @spec cancel_outbound(Instance.t(), String.t(), String.t()) ::
          :ok | {:error, :no_session | :unavailable | :timeout | :badarg}
  def cancel_outbound(instance, id, out_id),
    do: call(instance, id, {:cancel_outbound, out_id})

  # Tells the client to forget the requests the process `waiter` waits for.
  #
  @spec abandon_waiter(Instance.t(), String.t(), pid(), String.t()) ::
          :ok | {:error, :no_session | :unavailable | :timeout | :badarg}
  def abandon_waiter(instance, id, waiter, reason),
    do: call(instance, id, {:abandon_waiter, waiter, reason})

  # The session keeps the id of a task that runs and monitors its process,
  # so that the end of the session can stop it (`tasks_follow_session`) and a
  # dead task frees it. This cast runs in the process of the task.
  #
  @doc false
  @spec track_task(Instance.t(), String.t(), String.t()) :: :ok
  def track_task(instance, id, task_id), do: cast(instance, id, {:track_task, task_id, self()})

  @doc false
  @spec untrack_task(Instance.t(), String.t(), String.t()) :: :ok
  def untrack_task(instance, id, task_id), do: cast(instance, id, {:untrack_task, task_id})

  # The client sent `notifications/roots/list_changed`.
  #
  @spec mark_roots_changed(Instance.t(), String.t(), map()) :: sent()
  def mark_roots_changed(instance, id, ctx), do: cast(instance, id, {:roots_changed, ctx})

  # A session that is gone is unknown; no answer in time is a timeout.
  #
  defp call(instance, id, message) do
    :gen_statem.call(Instance.via(instance, {:session, id}), message, @call_timeout)
  rescue
    ArgumentError -> {:error, :unavailable}
  catch
    :exit, {:noproc, _call} -> {:error, :no_session}
    :exit, {:normal, _call} -> {:error, :no_session}
    :exit, {{:shutdown, _reason}, _call} -> {:error, :no_session}
    :exit, {:shutdown, _call} -> {:error, :no_session}
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :unavailable}
  end

  # A session that is gone is not an error: the message has no target.
  #
  defp cast(instance, id, message) do
    case Registry.lookup(Instance.names(instance), {:session, id}) do
      [{pid, _view}] -> :gen_statem.cast(pid, message)
      [] -> :ok
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init({instance, attrs}) do
    {:ok, config} = Instance.config(instance)
    opts = config.opts
    view = View.new(self(), attrs, System.monotonic_time(:millisecond))
    put_view(instance, attrs.session_id, view)

    # The entry lives as long as the process. The value is the session id.
    #
    _ =
      if view.principal_key do
        {:ok, _owner} =
          Registry.register(Instance.principals(instance), view.principal_key, attrs.session_id)
      end

    if view.principal_key, do: opts.pubsub.subscribe(instance, {:principal, view.principal_key})

    # The span starts after the view is in the Registry.
    #
    span =
      Telemetry.start(
        config.telemetry,
        :session,
        %{restored?: view.initialized},
        Map.get(attrs, :transport)
      )

    core = Core.new(instance, attrs, opts, view)

    data = %__MODULE__{
      core: core,
      telemetry: config.telemetry,
      span: span
    }

    # A session that starts from a snapshot holds the snapshot it got: a
    # change that gives the same persistent part writes nothing.
    #
    if view.initialized do
      core = Persistence.hold(core)
      {core, effects} = Subscriptions.topics(core)
      {data, actions} = Effects.run_init(effects, %{data | core: core})

      {:ok, :ready, data, [Core.idle_timer(core) | actions]}
    else
      {:ok, :initializing, data, [{{:timeout, :init}, opts.session_init_timeout_ms, :init}]}
    end
  end

  @impl true
  def handle_event(:info, {:DOWN, ref, :process, pid, _reason}, state, shell) do
    case Map.pop(shell.refs, ref) do
      {nil, _refs} ->
        :keep_state_and_data

      {tag, refs} ->
        shell = %{shell | refs: refs, monitors: Map.delete(shell.monitors, tag)}
        step({:down, tag, pid}, nil, state, shell)
    end
  end

  def handle_event({:call, from}, message, state, shell),
    do: step({:call, message}, from, state, shell)

  def handle_event(type, content, state, shell),
    do: step({type, content}, nil, state, shell)

  # The end of the session: the core gives the effects of the end, in
  # order: span, Registry, streams, requests, outbound, roots, tasks.
  #
  @impl true
  def terminate(reason, _state, shell) do
    {core, effects} = Core.terminate(shell.core, reason)
    _ = Effects.run(effects, %{shell | core: core}, nil, :closing)
    :ok
  end

  defp step(event, from, state, shell) do
    {core, effects} = Core.handle(event, state, shell.core)
    Effects.run(effects, %{shell | core: core}, from, state)
  end

  defp put_view(instance, session_id, view) do
    {_new, _old} =
      Registry.update_value(Instance.names(instance), {:session, session_id}, fn _ -> view end)

    :ok
  end
end
