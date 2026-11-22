#
# Runs one JSON-RPC message after the validation. The method comes from
# OzMcp.Method.Table and its code lives in the modules of
# `OzMcp.Handler`, one for each group of methods. Only `initialize`
# creates a session. A method without a row gets -32601; a notification
# ends with `:notified`.
#
# `handle_request/1` runs in the request process and answers what the
# transport writes.
#
defmodule OzMcp.Handler do
  @moduledoc false

  alias OzMcp.{Context, Method, Method.Table, Outbound}

  alias OzMcp.Handler.Reply

  require Logger

  # `:internal_error` means a store failed: the caller answers with its
  # server error, never with a success.
  #
  @type response() ::
          :notified
          | :internal_error
          | {:refused, :too_many_sessions}
          | {:rpc_success, map()}
          | {:rpc_error, map()}
          | {:session_created, String.t(), map()}

  @spec handle_request(Context.t()) :: response()
  def handle_request(context), do: context |> handle_request(nil) |> elem(0)

  # A caller without a stream passes `nil`.
  #
  @doc false
  @spec handle_request(Context.t(), OzMcp.Stream.t() | nil) ::
          {response(), OzMcp.Stream.t() | nil}
  def handle_request(%{rpc_response: response} = context, stream) when not is_nil(response) do
    Logger.debug("Client JsonRpc response")
    dispatch(context, stream)
  end

  def handle_request(context, stream) do
    Logger.debug("Call JsonRpc method: #{log_method(context.rpc_method)}")
    dispatch(context, stream)
  end

  # The method name comes from the client: escaped and bounded for the log.
  #
  defp log_method(method), do: inspect(method, printable_limit: 200)

  # The code of an error response of the client comes from the client
  # too: a number with too many digits stays out of the log.
  #
  @max_logged_code 2_147_483_647

  defp log_code(code) when is_integer(code) and abs(code) <= @max_logged_code,
    do: Integer.to_string(code)

  defp log_code(_code), do: "out of range"

  # An error response with no id waits for no request: only the code goes
  # to the log.
  #
  defp dispatch(%{rpc_response: {:orphan_error, error}}, stream) do
    Logger.warning("client error response with no id, code #{log_code(error["code"])}")
    {:notified, stream}
  end

  # A response is never answered (JSON-RPC 2.0): the router replies 202.
  #
  defp dispatch(%{rpc_response: answer} = context, stream) when not is_nil(answer) do
    Outbound.deliver(context, answer)
    {:notified, stream}
  end

  defp dispatch(%{rpc_method: name} = context, stream) do
    case Table.fetch(name) do
      {:ok, %Method{run: {module, fun}}} -> apply(module, fun, [context, stream])
      :error -> unknown(context, stream)
    end
  end

  # JSON-RPC 2.0 forbids replying to a notification. A message with such a
  # method and an id is refused by the envelope check, before this clause.
  #
  defp unknown(%{rpc_method: "notifications/" <> _rest} = context, stream) do
    Logger.debug("Unhandled notification: #{log_method(context.rpc_method)}")
    {:notified, stream}
  end

  defp unknown(context, stream) do
    Logger.debug("Unsupported method: #{log_method(context.rpc_method)}")
    Reply.error(context, -32601, "method not found", stream)
  end
end
