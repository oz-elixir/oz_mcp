#
# Where a notification of a task goes:
#
#   1. each attached `tasks/result` stream that the session of the
#      stream can serve;
#   2. else the topic of the principal that owns the task;
#   3. else the session of the task (a server with no authorization).
#
# A stream with no id, or with no session, counts as no stream: the
# message goes to the next target. A log carries the filter
# `{:log, level}` and each target applies it with the level of its
# receiving session.
#
defmodule OzMcp.Tasks.Notifier do
  @moduledoc false

  alias OzMcp.LogLevel
  alias OzMcp.Sessions
  alias OzMcp.Wire

  @type stream :: %{
          pid: pid(),
          stream_id: String.t() | nil,
          ref: reference(),
          session_id: String.t() | nil,
          capabilities: map()
        }

  @spec deliver(OzMcp.Instance.t(), map(), [stream()], map(), nil | {:log, atom()}) :: :ok
  def deliver(instance, record, streams, rpc_notification, filter \\ nil) do
    _ =
      case {live(streams), record.owner_key} do
        {[_ | _] = live, _owner} ->
          #
          # The notification is encoded one time, here. The session of each
          # stream gives the id of the event and logs it.
          #
          with {:ok, encoded} <- Wire.encode_message(rpc_notification) do
            for stream <- live,
                wanted?(instance, stream.session_id, filter) do
              send_to(instance, stream.session_id, {:stream, stream.stream_id}, encoded, filter)
            end
          end

        {[], {:principal, key}} ->
          Sessions.notify_principal(instance, key, rpc_notification, filter)

        {[], {:session, session_id}} ->
          if wanted?(instance, session_id, filter),
            do: send_to(instance, session_id, :session, rpc_notification, filter)
      end

    :ok
  end

  defp live(streams) do
    Enum.reject(streams, fn stream ->
      is_nil(stream.stream_id) or is_nil(stream.session_id)
    end)
  end

  # The session drops a message over `max_log_rate` before it emits it.
  #
  defp send_to(instance, session_id, target, message, {:log, _level}),
    do: Sessions.emit_log(instance, session_id, target, message)

  defp send_to(instance, session_id, target, message, nil),
    do: Sessions.emit(instance, session_id, target, message)

  defp wanted?(_instance, _session_id, nil), do: true

  defp wanted?(instance, session_id, {:log, level}) when is_binary(session_id) do
    case Sessions.delivery(instance, session_id) do
      {:ok, %{initialized: true, log_level: session_level}} ->
        LogLevel.wanted?(session_level, level)

      _other ->
        false
    end
  end

  defp wanted?(_instance, _session_id, _filter), do: false
end
