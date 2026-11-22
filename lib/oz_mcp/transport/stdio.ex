defmodule OzMcp.Transport.Stdio do
  @moduledoc """
  The MCP stdio transport: newline-delimited JSON-RPC on stdin and stdout.

  The transport serves one client that starts the process as a
  subprocess. Each line of stdin carries one JSON-RPC message; each
  message the server sends is written as one line of UTF-8 text on
  stdout. Nothing else may write to stdout: logs and stray prints
  belong on stderr (`OzMcp.Transport.Stdio.Console` prepares the
  devices and the Mix task `mix oz_mcp.stdio` calls it). The transport
  holds one session with no id on the wire: the first `initialize`
  creates it, the end of stdin ends it. A request that is not cheap
  (`tools/call`, `resources/read`, ...) runs in a process of its own,
  so a callback that waits for the client does not block the reading of
  the next lines; the cheap methods (`initialize`, `ping`,
  notifications, the answers of the client) run in the transport
  process, in the order of the lines.

  Authorization is not used on stdio: the client owns the process of
  the server. A server that declares an `authorization` block runs
  open — no principal, no scope check, no filter on the lists (see
  `OzMcp.Auth`).

  From any code, `run/2` runs a server on stdio and blocks until the
  connection ends; `start_link/1` starts the transport process alone,
  for a test or an entry of its own. The lifecycle, the refusals, the
  ordering of the lines and the limits are in the guide
  [stdio transport](guides/runtime/stdio_transport.md).

  ## The end of the connection

    * The end of stdin starts a drain: the transport waits for the
      requests in flight, up to `:drain_timeout_ms` (default 1000),
      then it ends the session and stops normally.
    * A failed write to stdout, or a failure of the reader of stdin (a
      `read` function that raises, or one that returns
      `{:error, reason}`), stops the transport with an error: no answer
      can reach, or no line will ever arrive.
    * The transport monitors the session process. When it stops (a
      crash, for example), the transport writes an error on stderr and
      stops with `{:shutdown, :session_lost}`. The Mix task then exits
      with code 1 and a message that names the case.
    * A request that gets `-32001` for the session of the connection
      (the instance lost the session) writes its error line first and
      the transport then stops with `{:shutdown, :session_lost}`: each
      later request would get the same error.
  """

  use GenServer

  @spec child_spec(keyword()) :: Supervisor.child_spec()

  alias OzMcp.{
    Context,
    Instance,
    Protocol,
    Session,
    Sessions,
    Telemetry,
    Validate,
    Wire
  }

  alias OzMcp.Transport.Stdio.{Reader, Request, Writer}
  alias OzMcp.Utils.{JsonRpc, Log}

  require Logger

  # Cheap and they keep the order of the lines.
  #
  @inline_methods ["initialize", "ping"]

  # How long the writer may write what is queued before the stop.
  #
  @flush_timeout_ms 1_000

  # How long the transport waits for the session process then.
  #
  @session_down_wait_ms 500

  # How long the transport waits for the requests in flight.
  #
  @default_drain_timeout_ms 1_000

  # How many messages may wait for stdout before the transport gives up.
  #
  @default_max_queue 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, check_opts!(opts))

  @doc """
  Runs a server on stdio and blocks until the connection ends. The
  options and the result values are in the guide
  [stdio transport](guides/runtime/stdio_transport.md); the caller
  prepares the `:read` and `:write` functions, so `run/2` itself
  changes no global state. When an instance with the name `:instance`
  runs, the transport joins it; when it does not run, `run/2` starts
  one in the stdio mode, with the server module and `:server_opts`.
  """
  @spec run(module(), keyword()) :: :ok | {:error, term()}
  def run(server, opts) do
    instance = Keyword.get(opts, :instance, server)

    transport_opts =
      check_opts!(
        instance: instance,
        read: Keyword.fetch!(opts, :read),
        write: Keyword.fetch!(opts, :write),
        drain_timeout_ms: Keyword.get(opts, :drain_timeout_ms, @default_drain_timeout_ms),
        max_queue: Keyword.get(opts, :max_queue, @default_max_queue)
      )

    with {:ok, config} <- ensure_server(instance, server, Keyword.get(opts, :server_opts, %{})),
         {:ok, transport} <-
           GenServer.start(__MODULE__, Keyword.put(transport_opts, :config, config)) do
      ref = Process.monitor(transport)

      receive do
        {:DOWN, ^ref, :process, _pid, :normal} -> :ok
        {:DOWN, ^ref, :process, _pid, reason} -> {:error, reason}
      end
    end
  end

  defp ensure_server(instance, server, server_opts) do
    case Instance.config(instance) do
      {:ok, config} ->
        {:ok, config}

      :not_running ->
        opts = Map.merge(server_opts, %{server: server, name: instance, transport: :stdio})
        config = Instance.Config.parse!(opts)

        with {:ok, _pid} <- Instance.start_link(config), do: {:ok, config}
    end
  end

  defp running_config(instance) do
    case Instance.config(instance) do
      {:ok, config} -> config
      :not_running -> nil
    end
  end

  defp check_opts!(opts) do
    case Keyword.get(opts, :drain_timeout_ms, @default_drain_timeout_ms) do
      ms when is_integer(ms) and ms >= 0 ->
        check_max_queue!(Keyword.put(opts, :drain_timeout_ms, ms))

      other ->
        raise ArgumentError,
              ":drain_timeout_ms must be an integer of 0 or more, got: #{inspect(other)}"
    end
  end

  defp check_max_queue!(opts) do
    case Keyword.get(opts, :max_queue, @default_max_queue) do
      n when is_integer(n) and n > 0 ->
        Keyword.put(opts, :max_queue, n)

      other ->
        raise ArgumentError, ":max_queue must be a positive integer, got: #{inspect(other)}"
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok, writer} =
      Writer.start_link(
        write: Keyword.fetch!(opts, :write),
        owner: self(),
        max_queue: Keyword.fetch!(opts, :max_queue)
      )

    {:ok, tasks} = Task.Supervisor.start_link()

    instance = Keyword.get(opts, :instance) || Keyword.fetch!(opts, :server)
    config = Keyword.get(opts, :config) || running_config(instance)

    state = %{
      instance: instance,
      #
      # The config of the instance, read one time at the start.
      #
      config: config,
      telemetry: config && config.telemetry,
      read: Keyword.fetch!(opts, :read),
      writer: writer,
      tasks: tasks,
      reader: nil,
      session_id: nil,
      session_ref: nil,
      running: %{},
      draining: false,
      drain_timeout_ms: Keyword.fetch!(opts, :drain_timeout_ms)
    }

    # The reader starts in a continue, after the registration.
    #
    {:ok, state, {:continue, :start_reader}}
  end

  @impl true
  def handle_continue(:start_reader, state) do
    {:ok, reader} = Reader.start_link(transport: self(), read: state.read)
    {:noreply, %{state | reader: reader}}
  end

  @impl true
  def handle_call({:line, line}, _from, state) do
    #
    # The reply is always :ok: a failure of one line is answered on
    # stdout.
    #
    case handle_line(line, state) do
      {:stop, reason, new_state} -> {:stop, reason, :ok, new_state}
      new_state -> {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_cast(:eof, %{drain_timeout_ms: 0} = state), do: {:stop, :normal, state}

  def handle_cast(:eof, %{running: running} = state) when map_size(running) == 0,
    do: {:stop, :normal, state}

  def handle_cast(:eof, state) do
    Logger.info("stdin ended, waiting for #{map_size(state.running)} request(s) in flight")
    Process.send_after(self(), :drain_timeout, state.drain_timeout_ms)
    {:noreply, %{state | draining: true}}
  end

  # The writer learns the end of the session from the stream, the
  # transport from the monitor, in either order. The reason decides the
  # exit, so the message of the monitor is taken first when it is on the
  # way.
  #
  @impl true
  def handle_info({:stdio_session_ended, writer}, %{writer: writer, session_ref: ref} = state)
      when is_reference(ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} = down -> handle_info(down, state)
    after
      @session_down_wait_ms -> {:stop, :normal, state}
    end
  end

  def handle_info({:stdio_session_ended, writer}, %{writer: writer} = state),
    do: {:stop, :normal, state}

  # A plain stop would leave no trace of the cause.
  #
  def handle_info({:EXIT, pid, {:shutdown, {:output_overflow, max}}}, %{writer: pid} = state) do
    Logger.error(
      "the stdout reader is too slow: more than #{max} messages wait for stdout " <>
        "(option :max_queue), the stdio transport stops"
    )

    {:stop, {:shutdown, {:output_overflow, max}}, state}
  end

  def handle_info({:EXIT, pid, reason}, %{writer: pid} = state), do: {:stop, reason, state}
  def handle_info({:EXIT, pid, reason}, %{tasks: pid} = state), do: {:stop, reason, state}

  # Any exit of the reader other than :normal is a failure: no line will
  # ever arrive, so the transport stops, as it does for a failed write.
  #
  def handle_info({:EXIT, pid, reason}, %{reader: pid} = state) when reason != :normal do
    text = describe_exit(reason)
    Logger.error("the stdin reader failed: " <> text)
    {:stop, {:shutdown, {:reader_failed, text}}, state}
  end

  # A normal exit of the reader (or of any other linked process) is not
  # an exit of the transport.
  #
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # The session process stopped. An end that the session asked for ends
  # the transport normally; any other end is a lost session. These
  # clauses stay before the clause of the request processes. The
  # init_timeout stop gets one error line.
  #
  def handle_info(
        {:DOWN, ref, :process, _pid, {:shutdown, :init_timeout}},
        %{session_ref: ref} = state
      ) do
    Logger.error(
      "the client did not send notifications/initialized in time " <>
        "(option session_init_timeout_ms): the stdio transport stops"
    )

    {:stop, {:shutdown, :init_timeout}, %{state | session_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, {:shutdown, _reason}}, %{session_ref: ref} = state) do
    {:stop, :normal, %{state | session_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{session_ref: ref} = state) do
    Logger.error(
      "the MCP session stopped (#{inspect(reason)}): the stdio transport stops, " <>
        "start the server again"
    )

    {:stop, {:shutdown, :session_lost}, %{state | session_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state = %{state | running: Map.delete(state.running, ref)}

    if state.draining and map_size(state.running) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:drain_timeout, %{draining: true} = state) do
    Logger.warning("the drain time ended, #{map_size(state.running)} request(s) cancelled")
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    #
    # Ending the session cancels the requests in flight (asynchronous);
    # the flush gives the queued lines one last chance.
    #
    if state.session_id do
      safely(fn -> Sessions.terminate(state.instance, state.session_id) end)
    end

    safely(fn -> Writer.flush(state.writer, @flush_timeout_ms) end)

    if state.reader, do: Process.exit(state.reader, :kill)

    if is_pid(state.writer) and Process.alive?(state.writer),
      do: Process.exit(state.writer, :kill)

    if is_pid(state.tasks) and Process.alive?(state.tasks), do: Process.exit(state.tasks, :kill)

    :ok
  end

  # -------------------------------------------------------------------
  # One line
  # -------------------------------------------------------------------

  defp handle_line(line, state) do
    case decode(line) do
      :blank ->
        state

      {:error, :parse} ->
        reply(state, JsonRpc.error(nil, -32700, "parse error"))

      {:error, :batch} ->
        reply(state, JsonRpc.error(nil, -32600, "batching is not supported"))

      {:error, :scalar} ->
        reply(state, JsonRpc.error(nil, -32600, "invalid request"))

      {:ok, rpc} ->
        process(rpc, state)
    end
  catch
    kind, reason ->
      Logger.error("stdio message failed: " <> Log.describe(kind, reason, __STACKTRACE__))
      reply(state, JsonRpc.error(nil, -32603, "internal error"))
  end

  defp decode(line) do
    case String.trim(line) do
      "" ->
        :blank

      text ->
        case Wire.decode(text) do
          {:ok, rpc} when is_map(rpc) -> {:ok, rpc}
          {:ok, list} when is_list(list) -> {:error, :batch}
          {:ok, _other} -> {:error, :scalar}
          {:error, :parse} -> {:error, :parse}
        end
    end
  end

  # The span of one message starts here; a child ends it after the
  # answer, in its own process.
  #
  defp process(rpc, state) do
    token =
      Telemetry.start(
        state.telemetry,
        :request,
        %{method: Protocol.bound_method(rpc), kind: JsonRpc.kind(rpc)},
        :stdio
      )

    case prepare(rpc, state, token) do
      {:refused, context} ->
        context |> Request.refuse(state.writer, token) |> apply_outcome(state)

      {:inline, context} ->
        context
        |> Request.inline(state.writer, token, &adopt_session(state, &1))
        |> apply_outcome(state)

      {:started, state} ->
        state
    end
  end

  # The catch below is the one place that ends the span of a raise
  # before the run of the message.
  #
  defp prepare(rpc, state, token) do
    context =
      Context.new(state.instance, :stdio, :rpc, state.config)
      |> Context.put_rpc(rpc)
      |> Map.put(:session_id, state.session_id)
      |> Validate.stdio()
      |> unwrap()

    cond do
      context.error -> {:refused, context}
      inline?(context) -> {:inline, context |> Validate.stdio_bind() |> unwrap()}
      true -> {:started, start_child(state, context, token)}
    end
  catch
    kind, reason ->
      Request.crashed(
        Request.request_id(rpc),
        state.writer,
        token,
        {kind, reason, __STACKTRACE__}
      )

      {:started, state}
  end

  # The token of the span is plain data.
  #
  defp start_child(state, context, token) do
    {:ok, pid} =
      Task.Supervisor.start_child(state.tasks, fn ->
        Request.child(context, state.writer, token)
      end)

    put_in(state, [:running, Process.monitor(pid)], pid)
  end

  # The monitor is armed before the stream opens: if the session stops
  # between the two steps, the transport sees it.
  #
  defp adopt_session(%{session_id: nil} = state, session_id) do
    with {:ok, pid} <- Instance.whereis(state.instance, {:session, session_id}),
         ref = Process.monitor(pid),
         :ok <- open_or_demonitor(state, session_id, ref) do
      %{state | session_id: session_id, session_ref: ref}
    else
      other ->
        Logger.error("cannot register the stream of the session: #{inspect(other)}")
        #
        # The session id goes into the state: terminate/2 ends the session.
        #
        {:stop, {:shutdown, {:stream_registration_failed, other}},
         %{state | session_id: session_id}}
    end
  end

  # The writer accepts only the messages of that stream.
  #
  defp open_writer_stream(state, session_id) do
    case Session.open_stream(state.instance, session_id, :stdio, state.writer, nil) do
      {:ok, %{stream_id: stream_id}} -> Writer.attach(state.writer, stream_id)
      other -> other
    end
  end

  defp open_or_demonitor(state, session_id, ref) do
    case open_writer_stream(state, session_id) do
      :ok ->
        :ok

      other ->
        Process.demonitor(ref, [:flush])
        other
    end
  end

  defp apply_outcome(%{next: next}, _state) when not is_nil(next), do: next

  defp apply_outcome(%{stop?: true}, state), do: session_lost(state)

  defp apply_outcome(_outcome, state), do: state

  # terminate/2 flushes the writer, so the error line reaches the client.
  #
  defp session_lost(state) do
    Logger.error(
      "the stdio session of #{inspect(state.instance)} is lost: the stdio transport stops, " <>
        "start the server again"
    )

    {:stop, {:shutdown, :session_lost}, state}
  end

  # The methods that must keep the order of the lines.
  #
  defp inline?(%{rpc_response: response}) when not is_nil(response), do: true
  defp inline?(%{rpc_id: nil}), do: true
  defp inline?(%{rpc_method: method}) when is_binary(method), do: method in @inline_methods

  # The lines that have no span of their own go out through here.
  #
  defp reply(state, message) do
    Request.write_line(state.writer, message)
    state
  end

  defp unwrap({:cont, context}), do: context

  defp unwrap({:halt, context}), do: context

  # For another reason than `:read_failed`, only the module of the
  # exception is kept: the stacktrace can hold arguments.
  #
  defp describe_exit({:read_failed, text}) when is_binary(text), do: text

  defp describe_exit({%{__exception__: true} = exception, _stacktrace}),
    do: "raised " <> inspect(exception.__struct__)

  defp describe_exit(reason), do: Log.describe(:exit, reason, [])

  defp safely(fun) do
    fun.()
  catch
    _kind, _reason -> :ok
  end
end
