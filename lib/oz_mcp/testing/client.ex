defmodule OzMcp.Testing.Client do
  @moduledoc false

  use GenServer

  alias OzMcp.Testing.{Adapter, Sse}
  alias OzMcp.Wire

  @impl true
  def init(opts) do
    state = %{
      instance: Keyword.fetch!(opts, :instance),
      router_opts: Keyword.fetch!(opts, :router_opts),
      headers: headers(Keyword.get(opts, :token)),
      session_id: nil,
      protocol_version: nil,
      next_id: 0,
      test_pid: Keyword.fetch!(opts, :test_pid),
      handle: Keyword.get(opts, :handle),
      timeout: Keyword.fetch!(opts, :timeout),
      pending: %{},
      initialize_id: nil,
      initialize_result: nil,
      get_pid: nil,
      get_buffer: ""
    }

    {:ok, state}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec initialize(pid(), map()) :: {:ok, map()} | {:error, map()}
  def initialize(client, params), do: GenServer.call(client, {:initialize, params}, :infinity)

  @spec request(pid(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def request(client, method, params, opts),
    do: GenServer.call(client, {:request, method, params, opts}, :infinity)

  @spec notify(pid(), String.t(), map(), keyword()) :: :ok | {:error, map()}
  def notify(client, method, params, opts),
    do: GenServer.call(client, {:notify, method, params, opts}, :infinity)

  @spec instance(pid()) :: atom()
  def instance(client), do: GenServer.call(client, :instance)

  @spec initialize_result(pid()) :: map()
  def initialize_result(client), do: GenServer.call(client, :initialize_result)

  @spec stop(pid()) :: :ok
  def stop(client), do: GenServer.call(client, :stop, :infinity)

  @impl true
  def handle_call({:initialize, params}, from, state) do
    {id, state} = take_id(state, nil)
    state = %{state | initialize_id: id}
    body = request_body(id, "initialize", params)

    {:noreply, start_post(state, body, {:post, id}, from, :request, state.timeout)}
  end

  def handle_call({:request, method, params, opts}, from, state) do
    if Map.has_key?(state.pending, {:post, opts[:id]}) do
      message = "the id #{inspect(opts[:id])} is in use by a pending call"
      {:reply, {:error, %{"code" => -32603, "message" => message}}, state}
    else
      {id, state} = take_id(state, opts[:id])
      body = request_body(id, method, params)
      timeout = Keyword.get(opts, :timeout, state.timeout)

      {:noreply, start_post(state, body, {:post, id}, from, :request, timeout)}
    end
  end

  def handle_call({:notify, method, params, opts}, from, state) do
    body = %{"jsonrpc" => "2.0", "method" => method, "params" => params}
    timeout = Keyword.get(opts, :timeout, state.timeout)
    tag = {:notify, make_ref()}

    {:noreply, start_post(state, body, tag, from, :notify, timeout)}
  end

  def handle_call(:instance, _from, state), do: {:reply, state.instance, state}

  def handle_call(:initialize_result, _from, state),
    do: {:reply, state.initialize_result, state}

  def handle_call(:stop, _from, state) do
    delete_session(state)

    for {_tag, entry} <- state.pending do
      GenServer.reply(
        entry.from,
        {:error, %{"code" => -32603, "message" => "the client stopped"}}
      )
    end

    {:stop, :shutdown, :ok, state}
  end

  @impl true
  def handle_info({_tag, :head, _status, _headers}, state), do: {:noreply, state}

  def handle_info({:get, :chunk, data}, state) do
    {events, buffer} = Sse.parse(state.get_buffer, data)
    state = %{state | get_buffer: buffer}
    {:noreply, Enum.reduce(events, state, &handle_event/2)}
  end

  def handle_info({tag, :chunk, data}, state) do
    case Map.fetch(state.pending, tag) do
      {:ok, entry} ->
        {events, buffer} = Sse.parse(entry.buffer, data)
        state = put_in(state.pending[tag].buffer, buffer)
        {:noreply, Enum.reduce(events, state, &handle_event/2)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:post_answer, body}, state) do
    post_answer(state, body)
    {:noreply, state}
  end

  def handle_info({:get, :done, _conn}, state), do: {:noreply, %{state | get_pid: nil}}

  def handle_info({tag, :done, conn}, state), do: {:noreply, handle_done(tag, conn, state)}

  def handle_info({:timeout, tag}, state), do: {:noreply, handle_timeout(tag, state)}

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_event(%{data: data}, state) do
    case Wire.decode(data) do
      {:ok, message} -> handle_message(message, state)
      {:error, _reason} -> state
    end
  end

  defp handle_message(%{"method" => "ping", "id" => id}, state) do
    post_answer(state, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
    state
  end

  defp handle_message(%{"method" => method, "id" => id} = message, state) do
    client = self()
    handle = state.handle
    params = Map.get(message, "params", %{})

    spawn_link(fn ->
      answer = run_handle(handle, method, params)
      send(client, {:post_answer, Map.put(answer, "id", id)})
    end)

    state
  end

  defp handle_message(%{"method" => method} = message, state) do
    send(state.test_pid, {:oz_mcp_notification, method, Map.get(message, "params", %{})})
    state
  end

  defp handle_message(%{"id" => id} = message, state) when is_binary(id) or is_integer(id),
    do: reply({:post, id}, message, state)

  defp handle_message(_message, state), do: state

  defp post_answer(state, body), do: spawn_post(state, body, {:answer, make_ref()})

  defp run_handle(nil, _method, _params), do: error(-32601, "method not found")

  defp run_handle(handle, method, params) do
    case handle.(method, params) do
      {:ok, result} when is_map(result) ->
        %{"jsonrpc" => "2.0", "result" => result}

      {:error, %{"code" => _code, "message" => _message} = error} ->
        %{"jsonrpc" => "2.0", "error" => error}

      _other ->
        error(-32603, "the handle function gave a wrong value")
    end
  rescue
    #
    # A clause error of the handle itself means an unhandled method; a deeper one is a bug.
    #
    error in FunctionClauseError ->
      if own_clause?(error, handle),
        do: error(-32601, "method not found"),
        else: error(-32603, "the handle function raised")

    _other ->
      error(-32603, "the handle function raised")
  catch
    _kind, _reason ->
      error(-32603, "the handle function raised")
  end

  defp own_clause?(%FunctionClauseError{module: module, function: name}, handle) do
    {:module, module} == Function.info(handle, :module) and
      {:name, name} == Function.info(handle, :name)
  end

  defp error(code, message),
    do: %{"jsonrpc" => "2.0", "error" => %{"code" => code, "message" => message}}

  defp handle_done({:post, id} = tag, conn, state) do
    if id == state.initialize_id,
      do: finish_initialize(tag, conn, state),
      else: finish_request(tag, conn, state)
  end

  defp handle_done({:notify, _ref} = tag, conn, state), do: finish_notify(tag, conn, state)
  defp handle_done(_tag, _conn, state), do: state

  defp finish_request(tag, conn, state) do
    if sse?(conn) do
      reply(tag, error_message("the stream ended with no answer"), state)
    else
      reply(tag, decode(conn), state)
    end
  end

  defp finish_initialize(tag, conn, state) do
    case Map.pop(state.pending, tag) do
      {nil, _pending} ->
        state

      {entry, pending} ->
        cancel(entry.timer)
        state = %{state | pending: pending, initialize_id: nil}

        case decode(conn) do
          %{"result" => result} ->
            session_id = conn |> Plug.Conn.get_resp_header("mcp-session-id") |> List.first()

            state = %{
              state
              | session_id: session_id,
                protocol_version: Map.get(result, "protocolVersion"),
                initialize_result: result
            }

            post_initialized(state, entry.from, result)

          %{"error" => error} ->
            GenServer.reply(entry.from, {:error, error})
            state

          _message ->
            GenServer.reply(entry.from, {:error, internal_error()})
            state
        end
    end
  end

  defp finish_notify(tag, conn, state) do
    case Map.pop(state.pending, tag) do
      {nil, _pending} ->
        state

      {entry, pending} ->
        cancel(entry.timer)
        answer = notify_answer(entry.kind, conn)
        GenServer.reply(entry.from, answer)
        state = %{state | pending: pending}
        maybe_start_get(entry.kind, answer, state)
    end
  end

  defp maybe_start_get({:initialized, _result}, {:ok, _answer}, state) do
    client = self()
    router_opts = state.router_opts
    headers = state.headers ++ session_headers(state)

    pid =
      spawn_link(fn ->
        conn =
          Plug.Test.conn(:get, "/")
          |> Plug.Conn.put_req_header("accept", "text/event-stream")
          |> put_headers(headers)
          |> Adapter.wrap(client, :get)

        conn = OzMcp.Router.call(conn, router_opts)
        send(client, {:get, :done, conn})
      end)

    %{state | get_pid: pid}
  end

  defp maybe_start_get(_kind, _answer, state), do: state

  defp delete_session(%{session_id: nil}), do: :ok

  defp delete_session(state) do
    _ =
      Plug.Test.conn(:delete, "/")
      |> put_headers(state.headers)
      |> put_headers(session_headers(state))
      |> OzMcp.Router.call(state.router_opts)

    :ok
  end

  defp notify_answer(kind, %Plug.Conn{status: 202}) do
    case kind do
      :notify -> :ok
      {:initialized, result} -> {:ok, result}
    end
  end

  defp notify_answer(_kind, conn), do: {:error, error_of(conn)}

  defp error_of(conn) do
    case decode(conn) do
      %{"error" => error} -> error
      _message -> internal_error()
    end
  end

  defp handle_timeout(tag, state) do
    case Map.pop(state.pending, tag) do
      {nil, _pending} ->
        state

      {entry, pending} ->
        message = %{"code" => -32603, "message" => "the request timed out"}
        GenServer.reply(entry.from, {:error, message})
        %{state | pending: pending}
    end
  end

  defp reply(tag, message, state) do
    case Map.pop(state.pending, tag) do
      {nil, _pending} ->
        state

      {entry, pending} ->
        cancel(entry.timer)
        GenServer.reply(entry.from, answer(message))
        %{state | pending: pending}
    end
  end

  defp answer(%{"result" => result}), do: {:ok, result}
  defp answer(%{"error" => error}), do: {:error, error}
  defp answer(_message), do: {:error, internal_error()}

  defp post_initialized(state, from, result) do
    body = %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}}
    tag = {:notify, make_ref()}

    start_post(state, body, tag, from, {:initialized, result}, state.timeout)
  end

  defp start_post(state, body, tag, from, kind, timeout) do
    spawn_post(state, body, tag)
    timer = Process.send_after(self(), {:timeout, tag}, timeout)
    entry = %{from: from, kind: kind, buffer: "", timer: timer}

    %{state | pending: Map.put(state.pending, tag, entry)}
  end

  defp spawn_post(state, body, tag) do
    {:ok, encoded} = Wire.encode(body)
    client = self()
    router_opts = state.router_opts
    headers = state.headers
    session_headers = session_headers(state)

    spawn_link(fn ->
      conn =
        Plug.Test.conn(:post, "/", encoded)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
        |> put_headers(headers)
        |> put_headers(session_headers)
        |> Adapter.wrap(client, tag)

      conn = OzMcp.Router.call(conn, router_opts)
      send(client, {tag, :done, conn})
    end)
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, key, value)
    end)
  end

  defp headers(nil), do: []
  defp headers(token), do: [{"authorization", "Bearer " <> token}]

  defp session_headers(%{session_id: nil}), do: []

  defp session_headers(%{session_id: session_id} = state) do
    case state.protocol_version do
      nil -> [{"mcp-session-id", session_id}]
      version -> [{"mcp-session-id", session_id}, {"mcp-protocol-version", version}]
    end
  end

  defp take_id(state, nil) do
    id = state.next_id + 1
    state = %{state | next_id: id}

    if Map.has_key?(state.pending, {:post, id}), do: take_id(state, nil), else: {id, state}
  end

  defp take_id(state, id), do: {id, state}

  defp request_body(id, method, params) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp sse?(conn) do
    case Plug.Conn.get_resp_header(conn, "content-type") do
      [content_type | _rest] -> String.starts_with?(content_type, "text/event-stream")
      [] -> false
    end
  end

  defp decode(conn) do
    case Wire.decode(conn.resp_body) do
      {:ok, %{} = message} -> message
      _other -> internal_error()
    end
  end

  defp error_message(message), do: %{"error" => %{"code" => -32603, "message" => message}}

  defp internal_error, do: %{"code" => -32603, "message" => "the server gave no answer"}

  defp cancel(timer) do
    _ = Process.cancel_timer(timer)
    :ok
  end
end
