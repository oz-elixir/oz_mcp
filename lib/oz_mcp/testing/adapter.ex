defmodule OzMcp.Testing.Adapter do
  @moduledoc false

  @behaviour Plug.Conn.Adapter

  alias Plug.Adapters.Test.Conn, as: Inner

  def wrap(%Plug.Conn{adapter: {Inner, state}} = conn, pid, tag),
    do: %{conn | adapter: {__MODULE__, {state, pid, tag}}}

  @impl true
  def send_resp({state, pid, tag}, status, headers, body) do
    {:ok, body, state} = Inner.send_resp(state, status, headers, body)
    {:ok, body, {state, pid, tag}}
  end

  @impl true
  def send_file({state, pid, tag}, status, headers, path, offset, length) do
    {:ok, body, state} = Inner.send_file(state, status, headers, path, offset, length)
    {:ok, body, {state, pid, tag}}
  end

  @impl true
  def send_chunked({state, pid, tag}, status, headers) do
    send(pid, {tag, :head, status, headers})
    {:ok, body, state} = Inner.send_chunked(state, status, headers)
    {:ok, body, {state, pid, tag}}
  end

  @impl true
  def chunk({state, pid, tag}, body) do
    send(pid, {tag, :chunk, IO.iodata_to_binary(body)})
    {:ok, body, state} = Inner.chunk(state, body)
    {:ok, body, {state, pid, tag}}
  end

  @impl true
  def read_req_body({state, pid, tag}, opts) do
    {:ok, body, state} = Inner.read_req_body(state, opts)
    {:ok, body, {state, pid, tag}}
  end

  @impl true
  def inform({state, _pid, _tag}, status, headers), do: Inner.inform(state, status, headers)

  @impl true
  def push({state, _pid, _tag}, path, headers), do: Inner.push(state, path, headers)

  @impl true
  def upgrade({state, _pid, _tag}, protocol, opts), do: Inner.upgrade(state, protocol, opts)

  @impl true
  def get_peer_data({state, _pid, _tag}), do: Inner.get_peer_data(state)

  @impl true
  def get_http_protocol({state, _pid, _tag}), do: Inner.get_http_protocol(state)
end
