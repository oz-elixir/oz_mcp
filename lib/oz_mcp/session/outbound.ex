#
# The requests that the session sends to the client. Each entry has the
# process that waits for the answer (the callback) and the route of its
# first message; the session monitors that process and when it goes
# away the client is told to forget the requests of that process.
#
# This module is not `OzMcp.Outbound`, the public API that a callback
# uses to send a request to the client.
#
# Owns the field `outbound` of `OzMcp.Session.Core` and the tag
# `:oz_mcp_client_answer` of the answer message. The first message of a
# request and the notices to the client are numbered in the same step,
# through `OzMcp.Session.Route`. `request/5` gives the reply `{id of
# the request, pid of the session process}`: the waiter can monitor
# the session, so its end ends the wait. A request of a task does not
# travel through the session.
#
# `abandon/3` tells the client to forget the requests the waiters that
# `wanted` selects still wait for: the framework uses it when it stops
# the process, which cannot do it itself.
#
defmodule OzMcp.Session.Outbound do
  @moduledoc false

  alias OzMcp.Session.{Core, Effect, Route}
  alias OzMcp.Utils.JsonRpc
  alias OzMcp.Wire

  @answer_tag :oz_mcp_client_answer

  # Stores a request to the client and routes its first message.
  #
  @spec request(Core.t(), pid(), {:request, String.t() | integer()}, String.t(), map() | nil) ::
          {Core.t(), [Effect.t()]}
  def request(core, waiter, {:request, request_id} = route, method, params) do
    out_id = unique_id(core)
    message = JsonRpc.request(out_id, method, params)

    case Wire.encode_message(message) do
      {:ok, encoded} ->
        entry = %{waiter: waiter, route: route}
        core = put_in(core.outbound[out_id], entry)
        {core, emit} = Route.request_or_session(core, request_id, encoded)

        {core,
         emit ++
           [
             {:monitor, waiter, {:outbound, out_id}},
             {:reply, {:ok, out_id, core.pid}},
             :idle_check
           ]}

      {:error, :not_encodable} = error ->
        {core, [{:reply, error}]}
    end
  end

  # The client answered: the waiter gets the outcome.
  #
  @spec deliver(Core.t(), String.t(), {:ok, map()} | {:error, term()}) ::
          {Core.t(), [Effect.t()]}
  def deliver(core, out_id, outcome) do
    case Map.pop(core.outbound, out_id) do
      {nil, _outbound} ->
        {core, []}

      {entry, outbound} ->
        {%{core | outbound: outbound},
         [
           {:demonitor, {:outbound, out_id}},
           {:send, entry.waiter, {@answer_tag, out_id, outcome}},
           :idle_check
         ]}
    end
  end

  # Cancels one request: the client is told to forget it.
  #
  @spec cancel(Core.t(), String.t(), String.t()) :: {Core.t(), [Effect.t()]}
  def cancel(core, out_id, reason) do
    case Map.pop(core.outbound, out_id) do
      {nil, _outbound} ->
        {core, [{:reply, :ok}]}

      {entry, outbound} ->
        core = %{core | outbound: outbound}
        {core, notice} = notice(core, entry, out_id, reason)

        {core, [{:demonitor, {:outbound, out_id}} | notice] ++ [{:reply, :ok}, :idle_check]}
    end
  end

  # Cancels the requests of the waiters that `wanted` selects.
  #
  @spec abandon(Core.t(), (map() -> boolean()), String.t()) :: {Core.t(), [Effect.t()]}
  def abandon(core, wanted, reason) do
    {mine, others} = Enum.split_with(core.outbound, fn {_id, entry} -> wanted.(entry) end)
    core = %{core | outbound: Map.new(others)}

    Enum.reduce(mine, {core, []}, fn {out_id, entry}, {core, effects} ->
      {core, notice} = notice(core, entry, out_id, reason)
      {core, effects ++ [{:demonitor, {:outbound, out_id}} | notice]}
    end)
  end

  # The process that waited for an answer is gone: the client is told.
  #
  @spec waiter_down(Core.t(), pid()) :: {Core.t(), [Effect.t()]}
  def waiter_down(core, waiter) do
    {core, effects} = abandon(core, &(&1.waiter == waiter), "the request ended")
    {core, effects ++ [:idle_check]}
  end

  # The end of the session: every waiter gets its error.
  #
  @spec end_all(Core.t()) :: {Core.t(), [Effect.t()]}
  def end_all(core) do
    effects =
      for {out_id, %{waiter: waiter}} <- core.outbound do
        {:send, waiter, {@answer_tag, out_id, {:error, :session_terminated}}}
      end

    {core, effects}
  end

  # The client is told to forget a request: the route of the entry
  # decides where the notice goes. A notice that JSON cannot encode
  # gives no effect.
  #
  defp notice(core, %{route: {:request, request_id}}, out_id, reason) do
    params = %{"requestId" => out_id, "reason" => reason}

    case Wire.encode_message(JsonRpc.notification("notifications/cancelled", params)) do
      {:ok, encoded} -> Route.request_or_session(core, request_id, encoded)
      {:error, :not_encodable} -> {core, []}
    end
  end

  defp unique_id(core) do
    id = core.ids.request_id()
    if Map.has_key?(core.outbound, id), do: unique_id(core), else: id
  end
end
