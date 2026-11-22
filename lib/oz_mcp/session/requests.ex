#
# The requests of the client that run in the session. The transport of
# a request registers it before the handler runs, so its id is unique
# among the requests of the session and it frees the id when the
# answer is out. A duplicate id is a defect of the client: it is
# refused with no spawn and the log names the id (escaped and
# bounded: it is client data).
#
# Owns the fields `requests` and `progress` of `OzMcp.Session.Core`.
# Each entry holds the owner of the request, the process of the
# callback, the id of the stream of its response and the last
# progress value. The field `progress` is the bounded map of the
# progress tokens that have no request entry (see `OzMcp.ProgressRule`).
#
# `pop_owner/2` is the DOWN of the owner: the caller joins the stop of
# the callback (`runner_stop_effects/3`), because the notices of the
# requests to the client belong to `OzMcp.Session.Outbound`. The
# caller also frees the stream when another process owns it (see
# `OzMcp.Session.Core`).
#
defmodule OzMcp.Session.Requests do
  @moduledoc false

  alias OzMcp.ProgressRule
  alias OzMcp.Session.{Core, Effect}

  @max_client_bytes 200

  # Registers a request of the client and monitors its owner.
  #
  # The server refuses only an id that is running.
  #
  @spec register(Core.t(), String.t() | integer(), pid()) ::
          {:ok, Core.t(), [Effect.t()]} | {:error, :duplicate, [Effect.t()]}
  def register(core, request_id, owner) do
    if Map.has_key?(core.requests, request_id) do
      {:error, :duplicate,
       [
         {:log, :warning,
          "request id #{inspect(request_id, printable_limit: @max_client_bytes)} is already in use"}
       ]}
    else
      request = %{owner: owner, runner: nil, stream_id: nil, progress: nil}

      {:ok, put_in(core.requests[request_id], request),
       [{:monitor, owner, {:request, request_id}}, :idle_check]}
    end
  end

  # Stores the process of the callback of a request.
  #
  @spec attach_runner(Core.t(), String.t() | integer(), pid()) :: {Core.t(), [Effect.t()]}
  def attach_runner(core, request_id, runner) do
    case Map.fetch(core.requests, request_id) do
      {:ok, %{runner: nil} = request} ->
        {put_in(core.requests[request_id], %{request | runner: runner}), [{:reply, :ok}]}

      {:ok, _already_attached} ->
        {core, [{:reply, :ok}]}

      :error ->
        {core, [{:reply, {:error, :no_request}}]}
    end
  end

  # The owner of the stream of a request, when it has one.
  #
  @spec owner(Core.t(), String.t() | integer()) :: {Core.t(), [Effect.t()]}
  def owner(core, request_id) do
    reply =
      case Map.fetch(core.requests, request_id) do
        {:ok, %{stream_id: stream_id, owner: owner}} when is_binary(stream_id) ->
          #
          # The owner of the entry is the truth: another process, or nil
          # after a hand-off. An entry that went already leaves the owner
          # of the request.
          #
          case Map.get(core.streams, stream_id) do
            %{owner: stream_owner} -> {:ok, {stream_owner, stream_id}}
            _no_entry -> {:ok, {owner, stream_id}}
          end

        _other ->
          :none
      end

    {core, [{:reply, reply}]}
  end

  # Frees the id of a request whose answer is out.
  #
  @spec finish(Core.t(), String.t() | integer()) :: {Core.t(), [Effect.t()]}
  def finish(core, request_id) do
    case Map.pop(core.requests, request_id) do
      {nil, _requests} ->
        {core, []}

      {_request, requests} ->
        {%{core | requests: requests}, [{:demonitor, {:request, request_id}}, :idle_check]}
    end
  end

  # Delivers the cancel of a request to its owner.
  #
  @spec cancel(Core.t(), String.t() | integer(), term()) :: {Core.t(), [Effect.t()]}
  def cancel(core, request_id, reason) do
    case Map.fetch(core.requests, request_id) do
      {:ok, request} ->
        {core, [{:send, request.owner, {:oz_mcp_cancel, request_id, reason}}]}

      :error ->
        {core, []}
    end
  end

  # Checks that a progress value increases and stores it.
  #
  @spec check_progress(Core.t(), {:request_or_session, term()} | :session, term(), term()) ::
          {:ok | :drop, Core.t()}
  def check_progress(core, :session, token, value), do: check_loose(core, token, value)

  def check_progress(core, {:request_or_session, request_id}, token, value) do
    case Map.fetch(core.requests, request_id) do
      {:ok, entry} ->
        case ProgressRule.check(Map.get(entry, :progress), value) do
          {:ok, last} ->
            {:ok, put_in(core.requests[request_id], Map.put(entry, :progress, last))}

          :drop ->
            {:drop, core}
        end

      :error ->
        check_loose(core, token, value)
    end
  end

  defp check_loose(core, token, value) do
    {result, loose} = ProgressRule.check_loose(core.progress, token, value)
    {result, %{core | progress: loose}}
  end

  # The owner is gone: the entry goes and the caller gets its runner, when
  # the request has one and the id of the stream of the request, when a
  # transport attached one.
  #
  @spec pop_owner(Core.t(), String.t() | integer()) ::
          {Core.t(), nil | :no_runner | pid(), nil | String.t()}
  def pop_owner(core, request_id) do
    case Map.pop(core.requests, request_id) do
      {nil, _requests} ->
        {core, nil, nil}

      {%{runner: nil} = request, requests} ->
        {%{core | requests: requests}, :no_runner, request.stream_id}

      {%{runner: runner} = request, requests} ->
        {%{core | requests: requests}, runner, request.stream_id}
    end
  end

  # The effects of the stop of a running callback.
  #
  @spec runner_stop_effects(Core.t(), pid(), [Effect.t()]) :: [Effect.t()]
  def runner_stop_effects(core, runner, abandon) do
    [
      {:log, :warning, "the caller of a running request went away, stopping the callback"}
    ] ++
      abandon ++
      [
        {:exit, runner, :shutdown},
        {:send_after, core.opts.request_cancel_grace_ms, {:kill_callback, runner}},
        :idle_check
      ]
  end

  # The stream of a request is over: a late emit has no target.
  #
  @spec clear_stream(Core.t(), String.t() | integer()) :: Core.t()
  def clear_stream(core, request_id) do
    case Map.get(core.requests, request_id) do
      %{stream_id: stream_id} = request when is_binary(stream_id) ->
        put_in(core.requests[request_id], %{request | stream_id: nil})

      _no_request_or_no_stream ->
        core
    end
  end

  # The end of the session: each owner gets the cancel of the end.
  #
  @spec end_all(Core.t()) :: {Core.t(), [Effect.t()]}
  def end_all(core) do
    effects =
      for {request_id, %{owner: owner}} <- core.requests do
        {:send, owner, {:oz_mcp_cancel, request_id, :session_terminated}}
      end

    {core, effects}
  end
end
