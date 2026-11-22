defmodule OzMcp.Handler.Resources do
  @moduledoc false

  alias OzMcp.Context
  alias OzMcp.Handler.{Invoke, Reply}
  alias OzMcp.Pipeline.Bound
  alias OzMcp.Sessions

  require Logger

  # The bind stage checked the uri and the resource (OzMcp.Pipeline.Bind).
  # The callback runs in isolation: a crash or a deadline overrun answers
  # a -32603 internal error, a cancel a -32800 error (see
  # OzMcp.Handler.Invoke).
  #
  @spec read(Context.t(), stream) :: {OzMcp.Handler.response(), stream} when stream: term()
  def read(%{bound: %Bound{kind: kind}} = context, stream) do
    %Bound{module: module, entity: entity, uri_params: uri_params, params: params} = context.bound

    ctx = Context.to_ctx(context)

    {outcome, stream} =
      case kind do
        :resource ->
          Invoke.run(
            context,
            fn ->
              module.read(ctx, params)
            end,
            stream: stream,
            telemetry_name: entity_name(entity)
          )

        :template ->
          Invoke.run(
            context,
            fn ->
              module.read(
                ctx,
                params,
                entity.uriTemplate,
                uri_params
              )
            end,
            stream: stream,
            telemetry_name: entity_name(entity)
          )
      end

    Reply.outcome(context, outcome, stream)
  end

  # The bind stage checked the uri (OzMcp.Validate.JsonRpc.params/1).
  #
  @spec subscribe(Context.t(), stream) :: {OzMcp.Handler.response(), stream} when stream: term()
  def subscribe(context, stream) do
    uri = context.rpc_params["uri"]

    # The scopes the resource needs: the session ends the subscription
    # when a later request shows a principal without them. A direct call
    # of the tests can have no bound entity.
    #
    required = (context.bound && context.bound.required_scopes) || []

    case Sessions.subscribe(context.instance, context.session_id, uri, required) do
      :ok ->
        Reply.success(context, %{}, stream)

      # The limit of the runtime option max_subscriptions_per_session
      # refused the URI. The params are valid, so the code is -32000
      # (like the other limits) and the data tells which limit.
      #
      {:error, :too_many_subscriptions} ->
        Reply.error(
          context,
          -32000,
          "too many subscriptions",
          %{"limit" => "max_subscriptions_per_session"},
          stream
        )

      error ->
        Logger.warning("resources/subscribe failed: #{inspect(error)}")
        Reply.internal(context, stream)
    end
  end

  # The params stage checked the uri (OzMcp.Validate.JsonRpc.params/1).
  #
  @spec unsubscribe(Context.t(), stream) :: {OzMcp.Handler.response(), stream} when stream: term()
  def unsubscribe(context, stream) do
    uri = context.rpc_params["uri"]

    case Sessions.unsubscribe(context.instance, context.session_id, uri) do
      :ok ->
        Reply.success(context, %{}, stream)

      error ->
        Logger.warning("resources/unsubscribe failed: #{inspect(error)}")
        Reply.internal(context, stream)
    end
  end

  # The declared name of a resource or of a template. The name that the
  # client asked for (the uri of the request) never goes to the telemetry.
  #
  defp entity_name(%{name: name}), do: name
  defp entity_name(_none), do: nil
end
