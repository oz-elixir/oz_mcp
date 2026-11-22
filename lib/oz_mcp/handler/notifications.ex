defmodule OzMcp.Handler.Notifications do
  @moduledoc false

  alias OzMcp.Context
  alias OzMcp.RootsChanged
  alias OzMcp.Sessions

  require Logger

  # The session was initialized before this message: nothing to write.
  # See OzMcp.Validate.Http.session/1.
  #
  @spec initialized(Context.t(), stream) :: {OzMcp.Handler.response(), stream}
        when stream: term()
  def initialized(%{session_initialized: true}, stream) do
    Logger.debug("duplicate notifications/initialized, ignored")
    {:notified, stream}
  end

  def initialized(context, stream) do
    #
    # The validation guaranteed a valid session (existing, owned, not
    # initialized): OzMcp.Validate.Http.session/1. A store that failed
    # during the write is a defect of the server: the session stays not
    # initialized and the caller answers with its server error. Any other
    # value (the session ended between the validation and the write) keeps
    # the acceptance of a notification: the client gets the refusal of an
    # unknown session at its next request.
    #
    case Sessions.set_initialized(context.instance, context.session_id) do
      {:error, reason} when reason in [:unavailable, :timeout] -> {:internal_error, stream}
      _ -> {:notified, stream}
    end
  end

  @spec cancelled(Context.t(), stream) :: {OzMcp.Handler.response(), stream} when stream: term()
  def cancelled(context, stream) do
    #
    # Spec: cancellation is best effort. The request is registered in its
    # session since the transport accepted it (see OzMcp.Session.open_request/5),
    # so the cancel reaches the process that waits for the result even
    # before the callback starts (see OzMcp.Sessions.cancel/4). A request
    # that already finished, an unknown id and an id of another session are
    # ignored. The work of a task is never cancelled here: tasks/cancel is.
    # Notifications never get a reply (JSON-RPC 2.0), so malformed params
    # are only logged.
    #
    _ =
      case context.rpc_params do
        %{"requestId" => request_id} = params
        when is_binary(request_id) or is_integer(request_id) ->
          reason = Map.get(params, "reason")
          reason = if is_binary(reason), do: reason

          _ = Sessions.cancel(context.instance, context.session_id, request_id, reason)

        _ ->
          Logger.warning("notifications/cancelled without a valid requestId, ignoring")
      end

    {:notified, stream}
  end

  @spec roots_list_changed(Context.t(), stream) :: {OzMcp.Handler.response(), stream}
        when stream: term()
  def roots_list_changed(context, stream) do
    #
    # The client tells that its roots changed. The server module decides
    # what to do (OzMcp.Config.Server roots_list_changed/1): it runs
    # detached, so it can ask the client for the roots without delaying
    # the 202 and a failure only reaches the log. OzMcp.RootsChanged
    # bounds the cost: one run per session, a burst coalesces.
    #
    if Context.client_supports?(context, :roots) do
      notify_roots_changed(context)
    else
      Logger.warning("notifications/roots/list_changed without the roots capability, ignoring")
    end

    {:notified, stream}
  end

  @spec tasks_status(Context.t(), stream) :: {OzMcp.Handler.response(), stream}
        when stream: term()
  def tasks_status(context, stream) do
    #
    # A hint only: the poll of the waiter is the source of truth. A hint
    # for an unknown task, for a task of another owner, or with bad params
    # is ignored. With the option client_tasks off, no waiter exists.
    #
    if OzMcp.Outbound.client_tasks?(context) do
      case context.rpc_params do
        %{"taskId" => task_id} when is_binary(task_id) ->
          OzMcp.Outbound.ClientTask.hint(context, task_id)

        _ ->
          Logger.warning("notifications/tasks/status without a valid taskId, ignoring")
      end
    end

    {:notified, stream}
  end

  defp notify_roots_changed(context) do
    RootsChanged.trigger(Context.to_ctx(context))
    :ok
  end
end
