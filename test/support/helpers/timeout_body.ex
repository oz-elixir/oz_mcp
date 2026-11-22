#
# Test support `Plug.Conn.Adapter` for a body that never arrives: it
# behaves like `Plug.Adapters.Test.Conn`, but each read of the request
# body fails with `{:error, :timeout}`, as on a client that sends the
# request head and no bytes of the body.
#
#     conn = Support.Helpers.TimeoutBody.wrap(conn)
#
defmodule Support.Helpers.TimeoutBody do
  alias Plug.Adapters.Test.Conn, as: Inner

  # Wraps a `Plug.Test` connection.
  #
  def wrap(%Plug.Conn{adapter: {Inner, state}} = conn),
    do: %{conn | adapter: {__MODULE__, state}}

  def send_resp(state, status, headers, body), do: Inner.send_resp(state, status, headers, body)

  def send_file(state, status, headers, path, offset, length),
    do: Inner.send_file(state, status, headers, path, offset, length)

  def send_chunked(state, status, headers), do: Inner.send_chunked(state, status, headers)
  def chunk(state, body), do: Inner.chunk(state, body)

  def read_req_body(_state, _opts), do: {:error, :timeout}

  def push(state, path, headers), do: Inner.push(state, path, headers)
  def inform(state, status, headers), do: Inner.inform(state, status, headers)
  def upgrade(state, protocol, opts), do: Inner.upgrade(state, protocol, opts)
  def get_peer_data(state), do: Inner.get_peer_data(state)
  def get_sock_data(state), do: Inner.get_sock_data(state)
  def get_ssl_data(state), do: Inner.get_ssl_data(state)
  def get_http_protocol(state), do: Inner.get_http_protocol(state)
end
