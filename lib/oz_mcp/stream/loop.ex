#
# The receive loop of one SSE connection: it runs in the process that owns
# the connection and returns the conn, which ends the response. The target
# module does the writes and decides the end; the loop calls its `idle/1`
# when the mailbox is empty for `heartbeat_ms`.
#
# Hazard: the loop has no catch-all clause, because the host server sends
# messages to this process that it must read itself. A stray message of an
# earlier request of the same process does no harm.
#
defmodule OzMcp.Stream.Loop do
  @moduledoc false

  alias OzMcp.Stream.Expiry
  alias OzMcp.Stream.Timers

  @type result :: {:cont, term()} | {:halt, Plug.Conn.t()}

  # A message of the own stream: an event, `:terminate`, `:end` or `:taken_over`.
  #
  @callback stream(payload :: term(), state :: term()) :: result()

  # The mailbox was empty for `heartbeat_ms`.
  #
  @callback idle(state :: term()) :: result()

  # A timer fired. The reason `:expired` reaches the target only when the
  # principal is expired: a live principal arms the timer again and the
  # target gets nothing.
  #
  @callback timer(reason :: :poll | :expired, state :: term()) :: result()

  # The session process stopped.
  #
  @callback session_down(state :: term()) :: result()

  # A message of the extra process (the worker of a `POST` request).
  #
  @callback message(payload :: term(), state :: term()) :: result()

  # The extra process stopped, with no message of it read before.
  #
  @callback aux_down(reason :: term(), state :: term()) :: result()

  defstruct [
    :target,
    :state,
    :stream_id,
    :heartbeat_ms,
    :principal,
    server_ref: nil,
    aux_ref: nil,
    poll_timer: nil,
    expiry_timer: nil
  ]

  @type t :: %__MODULE__{}

  @doc false
  @spec run(t()) :: Plug.Conn.t()
  def run(%__MODULE__{} = loop) do
    %__MODULE__{target: target, stream_id: stream_id, server_ref: server_ref, aux_ref: aux_ref} =
      loop

    poll_token = Timers.token(loop.poll_timer)
    expiry_token = Timers.token(loop.expiry_timer)

    receive do
      {:DOWN, ^server_ref, :process, _pid, _reason} ->
        next(loop, target.session_down(loop.state))

      {:DOWN, ^aux_ref, :process, _pid, reason} ->
        next(loop, target.aux_down(reason, loop.state))

      {:oz_mcp_stream, ^stream_id, payload} ->
        next(loop, target.stream(payload, loop.state))

      # A message for another stream: an old request of this process.
      #
      {:oz_mcp_stream, _other_stream, _payload} ->
        run(loop)

      {:sse_poll_close, ^poll_token} when not is_nil(poll_token) ->
        next(%{loop | poll_timer: nil}, target.timer(:poll, loop.state))

      # A poll message of another timer: an old request of this process. Drop it.
      #
      {:sse_poll_close, _other_token} ->
        run(loop)

      {:principal_expired, ^expiry_token} when not is_nil(expiry_token) ->
        case Expiry.check(loop.principal, loop.expiry_timer) do
          :expired ->
            next(%{loop | expiry_timer: nil}, target.timer(:expired, loop.state))

          # The delay of the timer was capped: wait for the rest. The
          # poll timer is not touched.
          #
          {:again, timer} ->
            run(%{loop | expiry_timer: timer})
        end

      # An expiry message of another timer: an old request of this process. Drop it.
      #
      {:principal_expired, _other_token} ->
        run(loop)

      {:oz_mcp_loop, ^aux_ref, payload} ->
        next(loop, target.message(payload, loop.state))

      # An old message of an extra process of a previous request of this
      # connection (HTTP/1.1 keep-alive). Drop it.
      #
      {:oz_mcp_loop, _other_ref, _payload} ->
        run(loop)

        # No catch-all clause: a message of the host server stays in
        # the mailbox for it to read.
        #
    after
      loop.heartbeat_ms ->
        next(loop, target.idle(loop.state))
    end
  end

  defp next(loop, {:cont, state}), do: run(%{loop | state: state})

  defp next(loop, {:halt, conn}) do
    stop(loop)
    conn
  end

  # The timers and the monitors are removed on every exit of the loop.
  # The cancel also removes a fired timer message from the mailbox and
  # a demonitor of a fired monitor does nothing.
  #
  defp stop(%__MODULE__{} = loop) do
    Expiry.cancel(loop.expiry_timer)
    Timers.cancel_poll(loop.poll_timer)

    if loop.server_ref, do: Process.demonitor(loop.server_ref, [:flush])
    if loop.aux_ref, do: Process.demonitor(loop.aux_ref, [:flush])

    :ok
  end
end
