defmodule OzMcp.Handler.Lifecycle do
  @moduledoc false

  alias OzMcp.Auth.Principal
  alias OzMcp.Context
  alias OzMcp.Handler.Reply
  alias OzMcp.Sessions
  alias OzMcp.Utils.JsonRpc

  # The session comes into existence only here: every check of the
  # validation passed and the result is ready. A store that fails, or a
  # runtime with no server, gives the server error of the caller.
  #
  @spec initialize(Context.t(), stream) :: {OzMcp.Handler.response(), stream}
        when stream: term()
  def initialize(context, stream) do
    rpc_response = JsonRpc.success(context.rpc_id, initialize_result(context))
    key = context.principal && Principal.key(context.principal)

    case Sessions.start(
           context.instance,
           owner: self(),
           transport: context.transport,
           protocol_version: context.negotiated_protocol_version,
           client_info: context.client_info,
           client_capabilities: context.client_capabilities,
           principal_key: key,
           config: context.config
         ) do
      {:ok, session_id} -> {{:session_created, session_id, rpc_response}, stream}
      {:error, :too_many_sessions} -> {{:refused, :too_many_sessions}, stream}
      {:error, _reason} -> {:internal_error, stream}
    end
  end

  @spec ping(Context.t(), stream) :: {OzMcp.Handler.response(), stream} when stream: term()
  def ping(context, stream), do: Reply.success(context, %{}, stream)

  # Level is already validated (OzMcp.Validate.JsonRpc.params/1). A store
  # that failed during the write is a defect of the server: the caller
  # answers with its server error and the level is not set. Any other
  # value (the session ended between the validation and the write) keeps
  # the success: the client gets the refusal of an unknown session at its
  # next request.
  #
  @spec set_level(Context.t(), stream) :: {OzMcp.Handler.response(), stream}
        when stream: term()
  def set_level(context, stream) do
    case Sessions.set_log_level(context.instance, context.session_id, context.log_level) do
      {:error, reason} when reason in [:unavailable, :timeout] ->
        {:internal_error, stream}

      _ ->
        Reply.success(context, %{}, stream)
    end
  end

  # The result of `initialize`: the frozen configuration of the server,
  # with the negotiated protocol version over the frozen one.
  #
  defp initialize_result(context) do
    config_result = context.server.initialize_result()

    protocol_version =
      context.negotiated_protocol_version || Map.get(config_result, :protocolVersion)

    Map.put(config_result, :protocolVersion, protocol_version)
  end
end
