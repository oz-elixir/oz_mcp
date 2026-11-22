#
# A JSON-RPC client of the MCP endpoint, over a real HTTP client (`Req`).
#
# The client keeps the session id and the protocol version. Each call
# answers `{client, {status, headers, body}}`: the client keeps the state
# that the answer gave (the session id, the negotiated protocol version)
# and the body is the decoded JSON, the parsed SSE events, or `nil` for
# an empty body.
#
# The client validates each message of an answer against the official
# schema: the result of each request against the result type of its
# method, an error response against the error shape and each
# notification and each server request against the union types. A
# message that does not conform fails the test.
#
defmodule OzMcp.E2E.Client do
  alias OzMcp.E2E.Conformance
  alias OzMcp.E2E.Sse

  defstruct base_url: nil,
            session_id: nil,
            protocol_version: "2025-11-25",
            headers: [],
            next_id: 1,
            requests: %{}

  @type t :: %__MODULE__{}

  @spec new(String.t(), list()) :: t()
  def new(base_url, headers \\ []) when is_binary(base_url),
    do: %__MODULE__{base_url: base_url, headers: headers}

  # A POST with one JSON-RPC message. The answer body is JSON, SSE or empty.
  #
  @spec post(t(), map(), keyword()) :: {t(), {integer(), list(), term()}}
  def post(%__MODULE__{} = client, message, opts \\ []) do
    response =
      Req.post!(
        client.base_url,
        [json: message, headers: headers(client, opts), decode_body: false, retry: false] ++
          client_opts(opts)
      )

    client = remember_session(client, response)
    {client, answer} = decode(client, response)
    {client, answer}
  end

  @spec request(t(), String.t(), map(), keyword()) :: {t(), {integer(), list(), term()}}
  def request(%__MODULE__{} = client, method, params \\ %{}, opts \\ []) do
    id = client.next_id

    message = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    client = %{client | next_id: id + 1, requests: Map.put(client.requests, id, method)}
    {client, answer} = post(client, message, opts)
    {client, answer}
  end

  @spec initialize(t(), keyword()) :: {t(), {integer(), list(), term()}}
  def initialize(%__MODULE__{} = client, opts \\ []) do
    params = %{
      "protocolVersion" => client.protocol_version,
      "capabilities" => Keyword.get(opts, :capabilities, %{}),
      "clientInfo" => %{"name" => "oz-mcp-e2e-client", "version" => "0.0.0"}
    }

    {client, {status, headers, body}} = request(client, "initialize", params, opts)

    client =
      case body do
        %{"result" => %{"protocolVersion" => version}} ->
          %{client | protocol_version: version}

        _ ->
          client
      end

    {client, {status, headers, body}}
  end

  @spec notify(t(), String.t(), map(), keyword()) :: {t(), {integer(), list(), term()}}
  def notify(%__MODULE__{} = client, method, params \\ %{}, opts \\ []) do
    post(client, %{"jsonrpc" => "2.0", "method" => method, "params" => params}, opts)
  end

  # A request with a method the harness does not build for you (a PUT, a
  # POST of a raw body, ...). The body goes on the wire as it is: the test
  # controls the exact bytes. Options:
  #
  #   * `:headers` - extra headers, after the default ones.
  #   * `:with_defaults` - when `false`, only the headers of the `:headers`
  #     option go out (no default `Accept` and `Origin`, no session id).
  #
  @spec send_raw(t(), atom(), binary() | nil, keyword()) ::
          {t(), {integer(), list(), term()}}
  def send_raw(%__MODULE__{} = client, method, body, opts \\ []) do
    headers =
      if Keyword.get(opts, :with_defaults, true),
        do: headers(client, opts),
        else: Keyword.get(opts, :headers, [])

    response =
      Req.request!(
        method: method,
        url: client.base_url,
        headers: headers,
        body: body,
        decode_body: false,
        retry: false
      )

    client = remember_session(client, response)
    {client, answer} = decode(client, response)
    {client, answer}
  end

  @spec delete(t(), keyword()) :: {t(), {integer(), list(), term()}}
  def delete(%__MODULE__{} = client, opts \\ []) do
    response =
      Req.delete!(client.base_url,
        headers: headers(client, opts),
        decode_body: false,
        retry: false
      )

    {client, answer} = decode(client, response)
    {client, answer}
  end

  # A client that is ready to send requests: initialize plus the
  # notifications/initialized notification.
  #
  @spec ready!(t(), keyword()) :: t()
  def ready!(%__MODULE__{} = client, opts \\ []) do
    {client, {200, _headers, %{"result" => %{"protocolVersion" => _}}}} = initialize(client, opts)
    {client, {202, _headers, nil}} = notify(client, "notifications/initialized")
    client
  end

  # ---- Open streams

  # A GET that opens the event stream of the session. The response is
  # asynchronous: the frames of the stream arrive in the mailbox of the
  # test process, one message per chunk (`open_get/2`, `next_frame/3`).
  # The option `:last_event_id` resumes where the client stopped: the log
  # replays the events the gap hid.
  #
  @spec open_get(t(), keyword()) :: {Req.Response.t(), Sse.state()}
  def open_get(%__MODULE__{} = client, opts \\ []) do
    headers =
      [{"accept", "text/event-stream"}, {"origin", "http://localhost"}] ++
        session_headers(client) ++ Keyword.get(opts, :headers, [])

    headers =
      case Keyword.fetch(opts, :last_event_id) do
        {:ok, id} -> headers ++ [{"last-event-id", id}]
        :error -> headers
      end

    response =
      Req.get!(
        client.base_url,
        [headers: headers, into: :self, retry: false] ++ client_opts(opts)
      )

    {response, Sse.new()}
  end

  # A POST whose response the test reads as an event stream while it is
  # open: the answer of the server can hold requests to the client before
  # the response of the request (see `OzMcp.PostStream`).
  #
  @spec stream_request(t(), String.t(), map(), keyword()) ::
          {t(), Req.Response.t(), Sse.state()}
  def stream_request(%__MODULE__{} = client, method, params \\ %{}, opts \\ []) do
    id = client.next_id

    message = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    client = %{client | next_id: id + 1, requests: Map.put(client.requests, id, method)}

    response =
      Req.post!(
        client.base_url,
        [
          headers: headers(client, opts),
          json: message,
          into: :self,
          decode_body: false,
          retry: false
        ] ++
          client_opts(opts)
      )

    {remember_session(client, response), response, Sse.new()}
  end

  # The answer of the client to a request of the server: a POST that
  # carries a JSON-RPC response for the id of the request.
  #
  @spec answer(t(), map(), term(), keyword()) :: {t(), {integer(), list(), term()}}
  def answer(%__MODULE__{} = client, %{"id" => id}, result, opts \\ []) do
    post(client, %{"jsonrpc" => "2.0", "id" => id, "result" => result}, opts)
  end

  # Closes the connection of an open stream. The server notices the loss
  # and stops the writes to it; the request the stream served goes on.
  #
  @spec cancel_stream(Req.Response.t()) :: :ok
  def cancel_stream(response) do
    Req.cancel_async_response(response)
    :ok
  end

  # The next frame of an open stream, whatever it carries (an event with
  # data, a priming event, a `retry` hint). `{:ended, state}` when the
  # stream is over: the connection closed.
  #
  @spec next_frame(Req.Response.t(), Sse.state(), pos_integer()) ::
          {:ok, Sse.t(), Sse.state()} | {:ended, Sse.state()}
  def next_frame(response, sse, timeout \\ 5_000) do
    case Sse.pop(sse) do
      {:ok, frame, sse} ->
        {:ok, frame, sse}

      :empty ->
        if Map.get(sse, :ended, false),
          do: {:ended, sse},
          else: receive_frame(response, sse, timeout)
    end
  end

  # The next event of an open stream: the frames that carry no message
  # (the priming events, the `retry` hints) are skipped and the message
  # of the event is validated against the official schema.
  #
  @spec next_event(Req.Response.t(), Sse.state(), pos_integer()) ::
          {:ok, Sse.t(), Sse.state()} | {:ended, Sse.state()}
  def next_event(response, sse, timeout \\ 5_000) do
    case next_frame(response, sse, timeout) do
      {:ok, %{data: ""}, sse} ->
        next_event(response, sse, timeout)

      {:ok, frame, sse} ->
        validate_streamed(JSON.decode!(frame.data))
        {:ok, frame, sse}

      {:ended, sse} ->
        {:ended, sse}
    end
  end

  # All the frames of a stream that ends by itself (a poll close, the end
  # of a resumed stream): `{:ended, frames, state}`.
  #
  @spec drain(Req.Response.t(), Sse.state(), pos_integer()) ::
          {:ended, [Sse.t()], Sse.state()}
  def drain(response, sse, timeout \\ 5_000), do: drain(response, sse, timeout, [])

  # The next raw chunk of an open stream, before the parsing of the SSE
  # frames: a test reads it to see the bytes that carry no event (the
  # heartbeats). `{:ok, data}`, or `:ended` when the stream is over.
  #
  @spec next_raw(Req.Response.t(), pos_integer()) :: {:ok, binary()} | :ended
  def next_raw(response, timeout \\ 5_000) do
    ref = stream_ref(response)

    receive do
      {^ref, _} = message ->
        case Req.parse_message(response, message) do
          {:ok, chunks} ->
            case raw_data(chunks) do
              "" -> if :done in chunks, do: :ended, else: next_raw(response, timeout)
              data -> {:ok, data}
            end

          {:error, reason} ->
            fail_stream(reason)

          :unknown ->
            next_raw(response, timeout)
        end
    after
      timeout -> fail_stream("no data within #{timeout} ms")
    end
  end

  defp headers(client, opts) do
    [{"accept", "application/json, text/event-stream"}, {"origin", "http://localhost"}] ++
      session_headers(client) ++ client.headers ++ Keyword.get(opts, :headers, [])
  end

  # The options of the HTTP client that a test can set. `:finch` names a
  # pool of the HTTP client: two requests on the same pool of one
  # connection reuse the connection (HTTP/1.1 keep-alive).
  #
  defp client_opts(opts) do
    opts
    |> Keyword.take([:finch, :receive_timeout])
    |> Enum.map(fn
      {:finch, name} when is_atom(name) -> {:finch, [name: name]}
      other -> other
    end)
  end

  defp session_headers(%__MODULE__{session_id: nil}), do: []

  defp session_headers(%__MODULE__{} = client),
    do: [
      {"mcp-session-id", client.session_id},
      {"mcp-protocol-version", client.protocol_version}
    ]

  defp remember_session(client, response) do
    case Req.Response.get_header(response, "mcp-session-id") do
      [id | _] -> %{client | session_id: id}
      [] -> client
    end
  end

  defp decode(client, %Req.Response{status: status, body: ""} = response),
    do: {client, {status, response.headers, nil}}

  defp decode(client, %Req.Response{status: status} = response) do
    case Req.Response.get_header(response, "content-type") do
      ["text/event-stream" <> _ | _] ->
        events = OzMcp.E2E.Sse.parse(response.body)
        client = validate_events(client, events)
        {client, {status, response.headers, events}}

      _ ->
        body = JSON.decode!(response.body)
        client = validate_message(client, body)
        {client, {status, response.headers, body}}
    end
  end

  # The priming event of a stream carries no data: nothing to validate.
  #
  defp validate_events(client, events) do
    events
    |> Enum.reject(&(&1.data == ""))
    |> Enum.reduce(client, fn event, acc ->
      validate_message(acc, JSON.decode!(event.data))
    end)
  end

  # A server request carries a method and an id.
  #
  defp validate_message(client, %{"method" => method, "id" => _id} = message)
       when is_binary(method) do
    Conformance.assert_server_request!(message)
    client
  end

  # A notification carries a method and no id.
  #
  defp validate_message(client, %{"method" => method} = message) when is_binary(method) do
    Conformance.assert_notification!(message)
    client
  end

  # The answer of a request: validate the result against the method.
  #
  defp validate_message(client, %{"id" => id, "result" => result}) do
    case Map.fetch(client.requests, id) do
      {:ok, method} ->
        Conformance.assert_result!(method, result)
        %{client | requests: Map.delete(client.requests, id)}

      :error ->
        client
    end
  end

  # An error answer.
  #
  defp validate_message(client, %{"id" => _id, "error" => _error} = message) do
    Conformance.assert_error_response!(message)
    client
  end

  defp validate_message(client, _other), do: client

  # ---- Internals of the open streams ----

  defp stream_ref(%Req.Response{body: %Req.Response.Async{ref: ref}}), do: ref

  defp stream_ref(_response), do: fail_stream("the response body is not an open stream")

  # The messages of a stream carry its ref: a receive on the ref reads the
  # chunks of this stream only, so two open streams never take each
  # other's chunks out of the mailbox.
  #
  defp receive_frame(response, sse, timeout) do
    ref = stream_ref(response)

    receive do
      {^ref, _} = message ->
        case Req.parse_message(response, message) do
          {:ok, chunks} ->
            sse =
              sse
              |> Sse.feed(raw_data(chunks))
              |> remember_done(chunks)

            next_frame(response, sse, timeout)

          {:error, reason} ->
            fail_stream(reason)

          :unknown ->
            receive_frame(response, sse, timeout)
        end
    after
      timeout -> fail_stream("no SSE frame within #{timeout} ms")
    end
  end

  defp remember_done(sse, chunks) do
    if :done in chunks, do: Map.put(sse, :ended, true), else: sse
  end

  defp drain(response, sse, timeout, frames) do
    case next_frame(response, sse, timeout) do
      {:ok, frame, sse} -> drain(response, sse, timeout, [frame | frames])
      {:ended, sse} -> {:ended, Enum.reverse(frames), sse}
    end
  end

  defp raw_data(chunks), do: for({:data, data} <- chunks, into: "", do: data)

  # A message that carries a method is a notification (no id) or a request
  # of the server (an id): both are validated against the official schema.
  # The message of an answer of the server is checked by the test.
  #
  defp validate_streamed(%{"method" => method, "id" => _} = message) when is_binary(method) do
    Conformance.assert_server_request!(message)
  end

  defp validate_streamed(%{"method" => method} = message) when is_binary(method) do
    Conformance.assert_notification!(message)
  end

  defp validate_streamed(_other), do: :ok

  defp fail_stream(reason) do
    raise ExUnit.AssertionError, message: "the stream failed: " <> inspect(reason)
  end
end
