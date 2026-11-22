#
# Checks the map that the snapshot module gives back from `load/2`: a
# map of the wrong shape must not reach the view of a session. A store
# that writes JSON must convert the map back to the type
# `OzMcp.Session.Snapshot.snapshot()` first.
#
defmodule OzMcp.Session.Snapshot.Check do
  @moduledoc false

  import OzMcp.LogLevel, only: [is_level: 1]

  alias OzMcp.Protocol

  @keys [
    :principal_key,
    :protocol_version,
    :client_info,
    :client_capabilities,
    :log_level,
    :subscriptions,
    :subscription_scopes
  ]

  # The keys that every snapshot must hold. `subscription_scopes` is
  # optional: a snapshot of a session with no scoped URI has no key.
  #
  @required_keys [
    :principal_key,
    :protocol_version,
    :client_info,
    :client_capabilities,
    :log_level,
    :subscriptions
  ]

  @spec run(term()) :: {:ok, map()} | {:error, atom()}
  def run(%{} = snapshot) when not is_struct(snapshot) do
    #
    # `Map.take/2` removes the keys that this library does not save.
    #
    snapshot = Map.take(snapshot, @keys)

    with :ok <- all_keys(snapshot),
         :ok <- principal_key(snapshot.principal_key),
         :ok <- protocol_version(snapshot.protocol_version),
         :ok <- optional_map(snapshot.client_info, :client_info),
         :ok <- required_map(snapshot.client_capabilities, :client_capabilities),
         :ok <- log_level(snapshot.log_level),
         :ok <- subscriptions(snapshot.subscriptions),
         :ok <- subscription_scopes(Map.get(snapshot, :subscription_scopes)) do
      #
      # The same form (unique, sorted) as the lists that the session
      # saves. A nil value (a store with a nullable column) removes the
      # key: the session would crash at its first touch.
      #
      snapshot = %{snapshot | subscriptions: snapshot.subscriptions |> Enum.uniq() |> Enum.sort()}

      snapshot =
        case Map.fetch(snapshot, :subscription_scopes) do
          {:ok, nil} -> Map.delete(snapshot, :subscription_scopes)
          {:ok, scopes} -> %{snapshot | subscription_scopes: normal_scopes(scopes)}
          :error -> snapshot
        end

      {:ok, snapshot}
    end
  end

  def run(_other), do: {:error, :not_a_map}

  # A map with string keys (a store that did not convert its JSON) has
  # none of the required keys: `Map.take/2` removed them.
  #
  defp all_keys(snapshot) do
    if(Enum.all?(@required_keys, &Map.has_key?(snapshot, &1)),
      do: :ok,
      else: {:error, :missing_key}
    )
  end

  # The same rule as the guard `is_principal_key/1` of `OzMcp.Sessions`.
  #
  defp principal_key(nil), do: :ok

  defp principal_key({issuer, subject})
       when (is_binary(issuer) or is_nil(issuer)) and is_binary(subject) and subject != "",
       do: :ok

  defp principal_key(_), do: {:error, :principal_key}

  # A version that the instance does not support can never match the
  # header of a request.
  #
  defp protocol_version(nil), do: :ok

  defp protocol_version(version) when is_binary(version),
    do: if(Protocol.supported?(version), do: :ok, else: {:error, :protocol_version})

  defp protocol_version(_), do: {:error, :protocol_version}

  defp optional_map(nil, _key), do: :ok
  defp optional_map(map, _key) when is_map(map) and not is_struct(map), do: :ok
  defp optional_map(_other, key), do: {:error, key}

  defp required_map(map, _key) when is_map(map) and not is_struct(map), do: :ok
  defp required_map(_other, key), do: {:error, key}

  defp log_level(nil), do: :ok
  defp log_level(level) when is_level(level), do: :ok
  defp log_level(_), do: {:error, :log_level}

  # A walk by hand: `Enum.all?/2` raises on a list that is not proper.
  #
  defp subscriptions(list) when is_list(list),
    do: if(all_binaries?(list), do: :ok, else: {:error, :subscriptions})

  defp subscriptions(_), do: {:error, :subscriptions}

  defp subscription_scopes(nil), do: :ok

  defp subscription_scopes(scopes) when is_map(scopes) and not is_struct(scopes) do
    if Enum.all?(scopes, fn {uri, required} ->
         is_binary(uri) and is_list(required) and all_binaries?(required)
       end),
       do: :ok,
       else: {:error, :subscription_scopes}
  end

  defp subscription_scopes(_), do: {:error, :subscription_scopes}

  # The same form (unique, sorted) as the lists that the session saves.
  #
  defp normal_scopes(scopes),
    do: Map.new(scopes, fn {uri, required} -> {uri, required |> Enum.uniq() |> Enum.sort()} end)

  # A walk by hand: `Enum.all?/2` raises on a list that is not proper.
  #
  defp all_binaries?([]), do: true
  defp all_binaries?([head | tail]) when is_binary(head), do: all_binaries?(tail)
  defp all_binaries?(_), do: false
end
