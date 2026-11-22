#
# The subscriptions of the session to its resources: the pubsub of the
# instance joins the topic of each URI that the session holds and the
# topic `:initialized` when the session starts. Owns the fields
# `subscriptions` and `subscription_scopes` of `OzMcp.Session.Core`;
# the scope lists are unique and sorted, so a restore does not write a
# different form back.
#
# A repeat subscribe of a URI in the set gives `:ok`. A new URI over
# `max_subscriptions_per_session` gives `{:error,
# :too_many_subscriptions}`. A touch without the required scopes of a
# URI ends that subscription.
#
defmodule OzMcp.Session.Subscriptions do
  @moduledoc false

  alias OzMcp.Session.{Core, Effect, Persistence}

  # Subscribes the session to a resource. A repeat subscribe replaces the scopes.
  #
  @spec subscribe(Core.t(), String.t(), [String.t()]) :: {Core.t(), [Effect.t()]}
  def subscribe(core, uri, required) do
    cond do
      MapSet.member?(core.subscriptions, uri) ->
        {core, save} = core |> put_scopes(uri, required) |> Persistence.save()
        {core, save ++ [{:reply, :ok}]}

      full?(core) ->
        {core,
         [
           {:limit, :max_subscriptions_per_session, core.opts.max_subscriptions_per_session},
           {:reply, {:error, :too_many_subscriptions}}
         ]}

      true ->
        join =
          if core.view.initialized,
            do: [{:pubsub, :subscribe, {:subscription, uri}}],
            else: []

        {core, save} =
          core |> put_scopes(uri, required) |> add(uri) |> Persistence.save()

        {core, join ++ save ++ [{:reply, :ok}]}
    end
  end

  # Removes the subscription to a resource and its scopes.
  #
  @spec unsubscribe(Core.t(), String.t()) :: {Core.t(), [Effect.t()]}
  def unsubscribe(core, uri) do
    core = %{
      core
      | subscriptions: MapSet.delete(core.subscriptions, uri),
        subscription_scopes: Map.delete(core.subscription_scopes, uri)
    }

    {core, save} = Persistence.save(core)
    {core, [{:pubsub, :unsubscribe, {:subscription, uri}}] ++ save ++ [{:reply, :ok}]}
  end

  # The check at each touch. The server learns the scopes of a token only
  # from a request, so a touch that carries the scopes of the principal
  # ends the subscriptions whose required scopes the list does not cover.
  # The end sends nothing to the client.
  #
  @spec drop_lost_scopes(Core.t(), [String.t()] | nil) :: {Core.t(), [Effect.t()]}
  def drop_lost_scopes(core, nil), do: {core, []}

  def drop_lost_scopes(%Core{subscription_scopes: scopes} = core, _granted)
      when map_size(scopes) == 0,
      do: {core, []}

  def drop_lost_scopes(%Core{subscription_scopes: scopes} = core, granted) do
    lost = for {uri, required} <- scopes, required -- granted != [], do: uri

    if lost == [] do
      {core, []}
    else
      core = %{
        core
        | subscriptions: MapSet.difference(core.subscriptions, MapSet.new(lost)),
          subscription_scopes: Map.drop(core.subscription_scopes, lost)
      }

      {core, save} = Persistence.save(core)

      unsubscribes = for uri <- lost, do: {:pubsub, :unsubscribe, {:subscription, uri}}

      {core,
       unsubscribes ++
         [{:telemetry, :subscription_dropped, %{count: length(lost)}, %{reason: :scope}}] ++ save}
    end
  end

  # The topics of the session: `:initialized` and the topic of each subscription.
  #
  @spec topics(Core.t()) :: {Core.t(), [Effect.t()]}
  def topics(core) do
    effects =
      [{:pubsub, :subscribe, :initialized}] ++
        for uri <- core.subscriptions, do: {:pubsub, :subscribe, {:subscription, uri}}

    {core, effects}
  end

  # The set of the subscriptions reached its limit.
  #
  @spec full?(Core.t()) :: boolean()
  def full?(%Core{opts: %{max_subscriptions_per_session: nil}}), do: false

  def full?(core),
    do: MapSet.size(core.subscriptions) >= core.opts.max_subscriptions_per_session

  defp put_scopes(core, uri, []),
    do: %{core | subscription_scopes: Map.delete(core.subscription_scopes, uri)}

  defp put_scopes(core, uri, required) do
    scopes = Map.put(core.subscription_scopes, uri, required |> Enum.uniq() |> Enum.sort())
    %{core | subscription_scopes: scopes}
  end

  defp add(core, uri), do: %{core | subscriptions: MapSet.put(core.subscriptions, uri)}
end
