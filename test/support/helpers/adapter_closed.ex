#
# Test support `Plug.Conn.Adapter` for a client that goes away: it behaves like
# `Plug.Adapters.Test.Conn`, but only the first `ok_chunks` chunks are written;
# the next ones fail with `{:error, :closed}`, as on a closed connection.
#
#     conn = Support.Helpers.AdapterClosed.wrap(conn, 1)
#
defmodule Support.Helpers.AdapterClosed do
  alias Plug.Adapters.Test.Conn, as: Inner

  # Wraps a `Plug.Test` connection.
  #
  def wrap(%Plug.Conn{adapter: {Inner, state}} = conn, ok_chunks),
    do: %{conn | adapter: {__MODULE__, {state, ok_chunks}}}

  def send_resp({state, n}, status, headers, body) do
    {:ok, body, state} = Inner.send_resp(state, status, headers, body)
    {:ok, body, {state, n}}
  end

  def send_file({state, n}, status, headers, path, offset, length) do
    {:ok, body, state} = Inner.send_file(state, status, headers, path, offset, length)
    {:ok, body, {state, n}}
  end

  def send_chunked({state, n}, status, headers) do
    {:ok, body, state} = Inner.send_chunked(state, status, headers)
    {:ok, body, {state, n}}
  end

  def chunk({_state, 0}, _body), do: {:error, :closed}

  def chunk({state, n}, body) do
    {:ok, body, state} = Inner.chunk(state, body)
    {:ok, body, {state, n - 1}}
  end

  def read_req_body({state, n}, opts) do
    {:ok, body, state} = Inner.read_req_body(state, opts)
    {:ok, body, {state, n}}
  end

  def inform({state, _n}, status, headers), do: Inner.inform(state, status, headers)
  def push({state, _n}, path, headers), do: Inner.push(state, path, headers)

  def get_peer_data({state, _n}), do: Inner.get_peer_data(state)
  def get_http_protocol({state, _n}), do: Inner.get_http_protocol(state)
end
