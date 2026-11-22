#
# A raw HTTP/1.1 client over one `:gen_tcp` socket, for the exchanges
# that `Req` cannot do: a body that never arrives in full, a body over
# the limit of the server and a request whose connection the test
# closes before the answer. The caller reads the bytes of the answer and
# closes the socket itself.
#
defmodule OzMcp.E2E.RawHttp do
  @type socket :: :gen_tcp.socket()

  # One connection to the endpoint of the test.
  #
  @spec connect(URI.t()) :: {:ok, socket()}
  def connect(%URI{} = uri) do
    :gen_tcp.connect(String.to_charlist(uri.host), uri.port, [:binary, active: false])
  end

  # Sends one request on the socket: the head names the host of the `uri`
  # and the `content-length` of the `body`, unless the option
  # `:content_length` promises another size (a body that never arrives in
  # full).
  #
  @spec request(socket(), String.t(), URI.t(), [{String.t(), String.t()}], binary(), keyword()) ::
          :ok
  def request(socket, method, %URI{} = uri, headers, body, opts \\ []) do
    length = Keyword.get(opts, :content_length, byte_size(body))

    head =
      "#{method} #{uri.path} HTTP/1.1\r\n" <>
        "host: #{uri.host}:#{uri.port}\r\n" <>
        Enum.map_join(headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end) <>
        "content-length: #{length}\r\n" <>
        "\r\n"

    :ok = :gen_tcp.send(socket, head <> body)
  end

  # One POST with the headers of a JSON body, on a connection of its own:
  # the caller closes the socket after the answer, so the server never
  # waits for bytes that do not come. Gives the status line and the rest
  # of the response.
  #
  @spec post(URI.t(), binary()) :: {:ok, String.t(), String.t()}
  def post(%URI{} = uri, body) do
    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"}
    ]

    {:ok, socket} = connect(uri)
    :ok = request(socket, "POST", uri, headers, body)
    {:ok, response} = read_response(socket)
    :ok = close(socket)
    [status_line | rest] = String.split(response, "\r\n", parts: 2)
    {:ok, status_line, Enum.join(rest, "\r\n")}
  end

  # Reads the bytes of one response with a JSON body. The answer may
  # arrive in more than one packet: the read goes on until the JSON body
  # is whole (the status line and the head come first). When the
  # connection ends before a body, what arrived comes back with the
  # reason of the end.
  #
  @spec read_response(socket(), pos_integer()) :: {:ok, String.t()}
  def read_response(socket, timeout \\ 20_000), do: read_response(socket, timeout, [])

  defp read_response(socket, timeout, acc) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} ->
        text = IO.iodata_to_binary([acc, data])

        if String.contains?(text, "}") do
          {:ok, text}
        else
          read_response(socket, timeout, [acc, data])
        end

      {:error, reason} ->
        {:ok, IO.iodata_to_binary(acc) <> "\n[socket: #{inspect(reason)}]"}
    end
  end

  # Closes the connection.
  #
  @spec close(socket()) :: :ok
  def close(socket), do: :ok = :gen_tcp.close(socket)
end
