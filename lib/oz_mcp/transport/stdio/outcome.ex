defmodule OzMcp.Transport.Stdio.Outcome do
  @moduledoc false

  alias OzMcp.Context.Error
  alias OzMcp.Utils.JsonRpc

  # The outcome of one stdio message, as pure data:
  #
  # span:  {:stop, extra_meta} | {:exception, kind, reason, stacktrace}
  # line:  the final message (a map), or nil when it gets no line
  # stop?: the transport must stop after the line (inline path only)
  # adopt: the session id the transport must adopt before the line
  # next:  what the adoption gave
  #
  defstruct span: nil, line: nil, stop?: false, adopt: nil, next: nil

  @type t :: %__MODULE__{}

  # After `:no_session` the inline path stops the transport (the child
  # path cannot; the monitor of the session does the stop).
  #
  @spec refusal({:error, term()}, term()) :: t()
  def refusal({:error, :duplicate}, id), do: error(:rpc_duplicate_request_id, id)
  def refusal({:error, :no_session}, id), do: %{error(:http_invalid_session, id) | stop?: true}
  def refusal({:error, _other}, id), do: error(:http_internal_error, id)

  # The line comes from the error of the context, which can hold data.
  #
  @spec validation(map()) :: t()
  def validation(%{error: error, rpc_id: id} = context) do
    {_status, body} = Error.build(error, id)

    %__MODULE__{
      span: stop(:error, error.code),
      line: if(answered?(context), do: body),
      stop?: error.code == :http_invalid_session and not is_nil(context.session_id)
    }
  end

  # One clause for each result of the handler, for both paths.
  #
  @spec from_handler(term(), term()) :: t()
  def from_handler({:rpc_success, response}, _id), do: ok(response)

  def from_handler({:rpc_error, response}, _id),
    do: %__MODULE__{span: stop(:rpc_error, nil), line: response}

  def from_handler(:notified, _id), do: ok(nil)

  def from_handler(:internal_error, nil),
    do: %__MODULE__{span: stop(:error, :http_internal_error)}

  def from_handler(:internal_error, id), do: error(:http_internal_error, id)

  def from_handler({:session_created, session_id, response}, _id),
    do: %{ok(response) | adopt: session_id}

  def from_handler({:refused, :too_many_sessions}, id), do: error(:http_too_many_sessions, id)

  # The inline path reports an exception event, the child path a stop.
  #
  @spec crashed(:inline | :child, term(), {atom(), term(), list()}) :: t()
  def crashed(:inline, id, {kind, reason, stacktrace}),
    do: %__MODULE__{span: {:exception, kind, reason, stacktrace}, line: crash_line(id)}

  def crashed(:child, id, _caught),
    do: %__MODULE__{span: stop(:error, nil), line: crash_line(id)}

  # A message that gets no answer: an answer of the client, valid or
  # not (JSON-RPC 2.0), or a notification.
  #
  defp answered?(%{rpc_kind: :response}), do: false

  # A refused message gets a line even with no id: an id of null is
  # not a notification and the client must learn why.
  #
  defp answered?(%{rpc_kind: :invalid}), do: true
  defp answered?(%{rpc_id: nil, rpc_method: "notifications/" <> _rest}), do: false
  defp answered?(_context), do: true

  defp ok(line), do: %__MODULE__{span: stop(:ok, nil), line: line}

  defp error(code, id) do
    {_status, body} = Error.build(Error.new(code), id)
    %__MODULE__{span: stop(:error, code), line: body}
  end

  defp stop(result, code), do: {:stop, %{status: nil, result: result, error_code: code}}
  defp crash_line(id), do: JsonRpc.error(id, -32603, "internal error")
end
