#
# The persistent part of a session. It goes to the snapshot module of
# the instance after each change that gives a snapshot the session does
# not hold yet and leaves the store when the session ends and the end
# is not a crash. A session that starts from a snapshot holds it
# (`saved`), so a change that gives the same persistent part writes
# nothing. Owns the fields `saved` and `retired` of `OzMcp.Session.Core`.
#
defmodule OzMcp.Session.Persistence do
  @moduledoc false

  alias OzMcp.Session.{Core, Effect}
  alias OzMcp.Session.Snapshot.None

  # The persistent part of the session, as the snapshot module stores it.
  #
  @spec persistent(Core.t()) :: map()
  def persistent(%Core{view: view, subscription_scopes: scopes} = core) do
    snapshot = %{
      principal_key: view.principal_key,
      protocol_version: view.protocol_version,
      client_info: view.client_info,
      client_capabilities: view.client_capabilities,
      log_level: view.log_level,
      subscriptions: core.subscriptions |> MapSet.to_list() |> Enum.sort()
    }

    if scopes == %{}, do: snapshot, else: Map.put(snapshot, :subscription_scopes, scopes)
  end

  # Holds the persistent part as the snapshot the session starts from.
  #
  @spec hold(Core.t()) :: Core.t()
  def hold(core), do: %{core | saved: persistent(core)}

  # Writes the snapshot of the session when it changed since the last write.
  #
  @spec save(Core.t()) :: {Core.t(), [Effect.t()]}
  def save(%Core{opts: %{session_snapshot: None}} = core), do: {core, []}
  def save(%Core{retired: true} = core), do: {core, []}

  def save(%Core{view: %{initialized: true}} = core) do
    snapshot = persistent(core)

    if snapshot == core.saved,
      do: {core, []},
      else: {%{core | saved: snapshot}, [{:snapshot, :save, snapshot}]}
  end

  def save(core), do: {core, []}

  # The session ends and its snapshot goes away. A second call does nothing.
  #
  @spec retire(Core.t()) :: {Core.t(), [Effect.t()]}
  def retire(%Core{retired: true} = core), do: {core, []}

  def retire(core) do
    delete =
      if core.opts.session_snapshot == None,
        do: [],
        else: [{:tombstone, core.id}, {:snapshot, :delete}]

    {%{core | retired: true}, delete ++ unregister(core)}
  end

  # The session leaves the Registry.
  #
  @spec unregister(Core.t()) :: [Effect.t()]
  def unregister(core) do
    principal = if core.view.principal_key, do: [{:unregister, :principals}], else: []
    principal ++ [{:unregister, :names}]
  end

  # A crash keeps the snapshot: the next request starts the session again.
  #
  @spec crash?(term()) :: boolean()
  def crash?(:normal), do: false
  def crash?(:shutdown), do: false
  def crash?({:shutdown, _reason}), do: false
  def crash?(_reason), do: true
end
