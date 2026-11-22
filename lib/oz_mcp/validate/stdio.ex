defmodule OzMcp.Validate.Stdio do
  @moduledoc false

  alias OzMcp.Pipeline
  alias OzMcp.Validate.Http

  # The session of a stdio connection. The transport puts the id of its
  # session in the context (nil before `initialize`).
  #

  # An answer of the client has no method. It needs no session to be read.
  #
  def session_id(%{rpc_response: response} = context) when not is_nil(response),
    do: {:cont, context}

  # The `initialize` handler creates the session (see OzMcp.Handler).
  #
  def session_id(%{rpc_method: "initialize", session_id: nil} = context), do: {:cont, context}

  def session_id(%{rpc_method: "initialize"} = context),
    do: Pipeline.halt(context, :rpc_already_initialized)

  def session_id(%{rpc_method: "ping"} = context), do: {:cont, context}

  def session_id(%{session_id: nil} = context),
    do: Pipeline.halt(context, :rpc_session_waiting_initialization)

  def session_id(context), do: {:cont, context}

  # The state check of HTTP: it works for a context of mode :rpc with no
  # connection.
  #
  defdelegate session(context), to: Http
end
