defmodule Support.Helpers.Utils do
  alias OzMcp.PostStream
  alias OzMcp.Session
  alias OzMcp.Sessions
  alias Support.Helpers.EventLogProbe
  alias Support.Servers

  @server Servers.Default

  # Encodes a message for the wire and gives the JSON text. A test builds
  # a message with it: a message that the wire refuses stops the test.
  #
  @spec encode_json(term()) :: binary()
  def encode_json(message) do
    {:ok, data} = OzMcp.Wire.encode(message)
    data
  end

  # Runs `fun` and returns the text of the compiler diagnostics (warnings and
  # errors) that the process of the caller emitted while `fun` ran.
  #
  # The diagnostics are collected for the calling process only. Unlike
  # `ExUnit.CaptureIO.capture_io(:stderr, ...)`, this is safe in async tests.
  #
  def capture_diagnostics(fun) do
    {_result, diagnostics} = Code.with_diagnostics(fun)

    Enum.map_join(diagnostics, "\n", & &1.message)
  end

  # Runs `fun` and returns the log text that the calling process (and the
  # processes it started with `Task`) wrote while `fun` ran.
  #
  # `ExUnit.CaptureLog.capture_log/2` captures the log of every process, so
  # in async tests it also holds the lines of other tests. Use this function
  # when the test checks that a line is absent or counts the lines. The
  # options: `:level` (the minimum level, default `:all`).
  #
  def capture_log(opts \\ [], fun) do
    ref = make_ref()
    Support.Helpers.LogHandler.register(self(), ref, Keyword.get(opts, :level, :all))

    try do
      fun.()
    after
      Support.Helpers.LogHandler.unregister(self())
    end

    collect_log(ref, [])
  end

  defp collect_log(ref, acc) do
    receive do
      {^ref, text} -> collect_log(ref, [text | acc])
    after
      0 -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  # Receives the next event that a stream process gets from the `Server`
  # and returns `{event_id, message}` with the JSON text decoded.
  #
  def receive_event(timeout \\ 5_000) do
    receive do
      {:oz_mcp_stream, _stream_id, {:event, event_id, data}} ->
        {event_id, data |> IO.iodata_to_binary() |> :json.decode()}
    after
      timeout -> ExUnit.Assertions.flunk("no event received within #{timeout} ms")
    end
  end

  # Starts one instance of `server` under the supervisor of the test. The
  # instance has its own Registries, processes and tables, so tests of
  # different files run at the same time. The name is unique unless the
  # test gives one (a test file that uses a fixed name builds it with
  # `Module.concat(server, __MODULE__)`).
  #
  def start_instance(server, opts \\ []) do
    {name, opts} =
      Keyword.pop_lazy(opts, :name, fn ->
        Module.concat(server, "T#{System.unique_integer([:positive])}")
      end)

    ExUnit.Callbacks.start_supervised!(
      {OzMcp, Keyword.merge([server: server, name: name, allowed_origins: []], opts)},
      id: {:instance, name}
    )

    Process.put(:test_instances, [name | Process.get(:test_instances, [])])
    :ok
  end

  # Receives the next message that a stream process gets from the `Server`
  # for the stream `stream_id` and returns it as it is
  # (`{:oz_mcp_stream, stream_id, payload}`).
  #
  def receive_stream_message(stream_id, timeout \\ 5_000) do
    receive do
      {:oz_mcp_stream, ^stream_id, _payload} = message -> message
    after
      timeout -> ExUnit.Assertions.flunk("no stream message received within #{timeout} ms")
    end
  end

  # The ids of the events of the body of an SSE response, in the order of
  # the wire. The priming event carries an id too.
  #
  def sse_ids(%Plug.Conn{resp_body: body}), do: sse_ids(body)

  def sse_ids(body) when is_binary(body),
    do: Regex.scan(~r/^id: (\S+)$/m, body, capture: :all_but_first) |> List.flatten()

  # Relays each message of the stream of the owner until all the emitter
  # tasks have replied, then gives the stream. The events that arrive while
  # the emitters run are written in the order of their ids. A task that
  # fails ends the wait with its reason.
  #
  def relay_until_done(stream, emitters) do
    refs = Map.new(Enum.map(emitters, & &1.ref), &{&1, true})
    do_relay_until_done(stream, refs)
  end

  defp do_relay_until_done(%PostStream{stream_id: stream_id} = stream, refs) do
    if map_size(refs) == 0 do
      stream
    else
      receive do
        {:oz_mcp_stream, ^stream_id, _payload} = message ->
          stream = PostStream.relay(stream, message)
          do_relay_until_done(stream, refs)

        {ref, _reply} when is_map_key(refs, ref) ->
          do_relay_until_done(stream, Map.delete(refs, ref))

        {:DOWN, ref, :process, _pid, reason}
        when is_map_key(refs, ref) and reason != :normal ->
          ExUnit.Assertions.flunk("an emitter ended with #{inspect(reason)}")

        {:DOWN, _ref, :process, _pid, :normal} ->
          do_relay_until_done(stream, refs)
      end
    end
  end

  # A JSON-RPC notification as encoded text, with a number in it: each
  # message of a test is different from the others.
  #
  def note(n),
    do: ~s({"jsonrpc":"2.0","method":"notifications/message","params":{"n":#{n}}})

  # Starts one instance for each entry (a server module, or `{module, opts}`
  # with a map of options). The name of each instance is the module with the
  # suffix `tag`: the test code addresses an instance with the same rule.
  #
  def start_instances(servers, tag, extra \\ []) do
    for entry <- servers do
      {server, opts} =
        case entry do
          {server, opts} -> {server, opts}
          server -> {server, %{}}
        end

      start_instance(server, [name: Module.concat(server, tag)] ++ Map.to_list(opts) ++ extra)
    end

    :ok
  end

  # Stops an instance that `start_instance/2` started.
  #
  def stop_instance(name) do
    ExUnit.Callbacks.stop_supervised!({:instance, name})
    Process.put(:test_instances, List.delete(Process.get(:test_instances, []), name))
    :ok
  end

  # Stops every instance that the test started.
  #
  def stop_instances do
    for name <- Process.get(:test_instances, []), do: stop_instance(name)
    :ok
  end

  def generate_session_id do
    :crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower)
  end

  # The owner of a request of a session opens the request and its stream in
  # one call (the transport does it before the handler runs). A session that
  # does not exist (or an id that is not a request id) gives a stream with
  # no target.
  #
  def begin_stream(instance, session_id, request_id, conn, prepare) do
    case OzMcp.PostStream.begin(instance, session_id, request_id, conn, prepare) do
      {:error, :no_session} ->
        OzMcp.PostStream.begin(instance, nil, nil, conn, prepare)

      result ->
        result
    end
  end

  def begin_sink(instance, session_id, request_id, sink) do
    OzMcp.PostStream.begin_sink(instance, session_id, request_id, sink)
  end

  # Opens a request of a session, with the entry of its stream when `stream`
  # is not `nil`. `stream` is `{stream_id, :sse | :sink}`.
  #
  def open_request(instance, session_id, request_id, owner \\ self(), stream \\ nil) do
    OzMcp.Session.open_request(instance, session_id, request_id, owner, stream)
  end

  # Ends the stream of a request in one call. `final` is
  # `{:response, encoded, started?}` or `:detach`.
  #
  def close_request(instance, session_id, request_id, stream_id, final) do
    OzMcp.Session.close_request(instance, session_id, request_id, stream_id, final)
  end

  # Writes the time of the last activity of a session in its view and in
  # the Registry, so a test fixes the order of the reclaim with no wait.
  #
  def set_last_active(instance, session_id, at) do
    {:ok, pid} = OzMcp.Instance.whereis(instance, {:session, session_id})

    :sys.replace_state(pid, fn {name, state} ->
      view = %{state.core.view | last_active_ms: at}

      Registry.update_value(OzMcp.Instance.names(instance), {:session, session_id}, fn _ ->
        view
      end)

      {name, put_in(state.core.view, view)}
    end)

    :ok
  end

  # The owner key of the tasks of a session of a server with no authorization.
  #
  def owner(session_id), do: OzMcp.Tasks.owner_key(%{principal: nil, session_id: session_id})

  def create_session, do: create_session(@server, [])

  def create_session(module) when is_atom(module),
    do: create_session(module, [])

  def create_session(opts) when is_list(opts), do: create_session(@server, opts)

  def create_session(module, opts) do
    streams = Keyword.get(opts, :streams, [])
    capabilities = Keyword.get(opts, :client_capabilities, %{})
    principal_key = Keyword.get(opts, :principal_key)

    {:ok, session_id} =
      Sessions.start(module,
        client_capabilities: capabilities,
        principal_key: principal_key
      )

    if Keyword.get(opts, :initialized, false) do
      :ok = Sessions.set_initialized(module, session_id)
    end

    maybe_register_streams(module, session_id, streams)

    # A stream that is already dead is removed at the :DOWN that its
    # monitor delivers: wait for it.
    #
    if streams != [], do: sync_server(module, session_id)
    session_id
  end

  # The kind :stdio opens a stream with no priming id in the reply and no
  # ring in the log.
  #
  defp maybe_register_streams(_module, _session_id, []), do: nil

  defp maybe_register_streams(module, session_id, [stream | rest]) do
    {:ok, _} = Session.open_stream(module, session_id, :stdio, stream, nil)
    maybe_register_streams(module, session_id, rest)
  end

  # A call of the session that changes nothing the test observes: it
  # answers after every cast that was sent before it, so a test can order
  # a cast and a read that must see the effect of the cast.
  #
  def sync_server(module, session_id) do
    case OzMcp.Instance.whereis(module, {:session, session_id}) do
      {:ok, pid} -> :sys.get_state(pid)
      :not_running -> :ok
    end

    :ok
  end

  # The same for a task that runs: it answers after every cast that was
  # sent before it.
  #
  def sync_task(instance, task_id) do
    case OzMcp.Instance.whereis(instance, {:task, task_id}) do
      {:ok, pid} -> :sys.get_state(pid)
      :not_running -> :ok
    end

    :ok
  end

  # The GET streams of a session, newest first: a list of maps with the
  # keys `:id`, `:pid` and `:kind`. They are the state of the session
  # process.
  #
  def session_streams(instance, session_id) do
    case session_data(instance, session_id) do
      nil -> []
      data -> data.get_streams
    end
  end

  # The plain map of the state of the session process, or nil when the
  # session is not running. It is the state of the process: a test reads
  # it to see the streams and the event log.
  #
  def session_data(instance, session_id) do
    case OzMcp.Instance.whereis(instance, {:session, session_id}) do
      {:ok, pid} ->
        {_state_name, core} = Support.Helpers.SessionProbe.core(pid)
        core

      :not_running ->
        nil
    end
  end

  # The retained events of one stream of a session after an event id
  # (all of them when the id is `nil`), or `:gap` when the log holds no ring
  # for the stream or no event with that id.
  #
  def events_after(instance, session_id, stream_id, last_id) do
    case session_data(instance, session_id) do
      nil -> {:error, :no_session}
      data -> EventLogProbe.after_id(data.log, stream_id, last_id)
    end
  end

  def stream_pids(instance, session_id),
    do: instance |> session_streams(session_id) |> Enum.map(& &1.pid)

  # Calls `fun` until it returns a truthy value or until `timeout` ms pass.
  # Gives `true` when `fun` returned a truthy value, `false` at the end of
  # the time. Use it as `assert Support.Helpers.Utils.eventually(fn -> ... end)`.
  #
  # A test waits for an event of the library with this function, never with
  # a `Process.sleep` of a fixed length.
  #
  @spec eventually((-> term()), pos_integer()) :: boolean()
  def eventually(fun, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        false
      else
        #
        # One short wait between two tries of the condition. This is the
        # only timed wait of the helper.
        #
        Process.sleep(10)
        do_eventually(fun, deadline)
      end
    end
  end

  # Sends `:terminate` to a GET stream: the stream ends as it does when its
  # session ends.
  #
  def terminate_stream(instance, session_id, pid) do
    %{id: stream_id} = Enum.find(session_streams(instance, session_id), &(&1.pid == pid))
    send(pid, {:oz_mcp_stream, stream_id, :terminate})
  end

  def wait_for_stream(instance, session_id, pid, timeout \\ 15_000) do
    wait_for(fn -> pid in stream_pids(instance, session_id) end, timeout, "stream was not opened")
  end

  def wait_for_stream_gone(instance, session_id, pid, timeout \\ 15_000) do
    wait_for(
      fn -> pid not in stream_pids(instance, session_id) end,
      timeout,
      "stream was not closed"
    )
  end

  defp wait_for(fun, timeout, message) do
    if eventually(fun, timeout) do
      :ok
    else
      ExUnit.Assertions.flunk(message)
    end
  end

  # The loss of a session: its entry leaves the Registry, so a lookup finds
  # no session, while the process and the streams stay. The write runs
  # inside the session process, the owner of its entry.
  #
  def session_delete(instance, session_id) do
    {:ok, pid} = OzMcp.Instance.whereis(instance, {:session, session_id})

    :sys.replace_state(pid, fn state ->
      Registry.unregister(OzMcp.Instance.names(instance), {:session, session_id})
      state
    end)

    :ok
  end

  # The sessions of an instance: a list of `{session_id, view}`.
  #
  def sessions(instance) do
    OzMcp.Instance.select(instance, [{{{:session, :"$1"}, :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
  end

  # The number of sessions of an instance.
  #
  def session_count(instance), do: instance |> sessions() |> length()

  # The subscriptions of a session (a list of URIs), or nil when the session
  # is not running.
  #
  def subscriptions(instance, session_id) do
    case session_data(instance, session_id) do
      nil -> nil
      data -> data.subscriptions |> MapSet.to_list() |> Enum.sort()
    end
  end

  @runtime_name Support.Helpers.Utils.Runtime

  # Starts one instance for each server entry of `config`
  # (`%{servers: [module | {module, opts}], allowed_origins: [...], transport: ...}`)
  # under one supervisor that the caller links. `stop_runtime/0` stops it.
  # Each instance has the name of its server module.
  #
  def start_runtime(%{servers: servers} = config) do
    global = Map.take(config, [:allowed_origins, :transport])

    children =
      for entry <- servers do
        {module, opts} =
          case entry do
            {module, opts} -> {module, opts}
            module -> {module, %{}}
          end

        Supervisor.child_spec(
          {OzMcp, [{:server, module} | Map.to_list(Map.merge(global, opts))]},
          []
        )
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: @runtime_name)
  end

  # The child spec of `start_runtime/1`, for `start_supervised!/1`.
  #
  def runtime_spec(config),
    do: %{id: @runtime_name, start: {__MODULE__, :start_runtime, [config]}, type: :supervisor}

  def runtime_running?, do: Process.whereis(@runtime_name) != nil

  def stop_runtime do
    case Process.whereis(@runtime_name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        try do
          Supervisor.stop(pid)
        catch
          :exit, _ -> :ok
        end

        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        end

        :ok
    end
  end
end
