#
# The check of one value of one row of `OzMcp.Instance.Config.Schema`.
# Each function gives the value back, so one loop can validate and
# normalize (for example `nil` becomes `[]` for `allowed_origins`).
#
defmodule OzMcp.Instance.Config.Check do
  @moduledoc false

  @spec value(OzMcp.Instance.Config.Schema.row(), term(), atom()) :: term()
  def value({key, :pos_int, _default, flags}, value, _server) do
    cond do
      is_integer(value) and value > 0 and within_max?(value, flags) ->
        value

      value == nil and flags[:null] ->
        value

      value == :infinity and flags[:infinity] ->
        value

      true ->
        raise ArgumentError, "#{key} must be #{describe_pos(flags)}, got: #{inspect(value)}"
    end
  end

  def value({key, :non_neg_int, _default, _flags}, value, _server) do
    if is_integer(value) and value >= 0 do
      value
    else
      raise ArgumentError, "#{key} must be a non-negative integer, got: #{inspect(value)}"
    end
  end

  def value({key, :boolean, _default, _flags}, value, _server) do
    #
    # `nil` is not a boolean. The merge of the defaults gives the default
    # when the key is missing, so a `nil` here is always a mistake of the
    # caller.
    #
    if is_boolean(value) do
      value
    else
      raise ArgumentError, "#{key} must be a boolean, got: #{inspect(value)}"
    end
  end

  # The optional index callbacks of the task store must be all present or
  # all absent: a store with a partial set would mix its own index with
  # the default index of the facade. A partial set is refused here and
  # the message names the missing functions.
  #
  def value({:task_store, {:module, label, required}, _default, _flags}, value, server) do
    store = value({nil, {:module, label, required}, nil, []}, value, server)

    callbacks = OzMcp.Tasks.Records.index_callbacks()

    missing =
      for {name, arity} <- callbacks,
          not function_exported?(store, name, arity),
          do: "#{name}/#{arity}"

    if missing != [] and length(missing) != length(callbacks) do
      raise ArgumentError,
            "server #{inspect(server)}: the task store #{inspect(store)} must export " <>
              "the index callbacks all together or not at all, " <>
              "missing: #{Enum.join(missing, ", ")}"
    end

    store
  end

  def value({_key, {:module, label, required}, _default, _flags}, value, server) do
    missing =
      if Code.ensure_loaded?(value) do
        for {name, arity} <- required,
            not function_exported?(value, name, arity),
            do: "#{name}/#{arity}"
      else
        Enum.map(required, fn {name, arity} -> "#{name}/#{arity}" end)
      end

    if missing != [] do
      raise ArgumentError,
            "server #{inspect(server)}: the #{label} #{inspect(value)} " <>
              "must export #{Enum.join(missing, ", ")}"
    end

    value
  end

  def value({key, :custom, _default, _flags}, value, server), do: custom(key, value, server)

  # A relation compares two options. It applies only when both values
  # are integers (`nil` is a valid value of the keys of `:at_most`).
  #
  @spec relation!(tuple(), map()) :: :ok
  def relation!({:at_most, key, cap}, opts) do
    value = Map.get(opts, key)
    limit = Map.get(opts, cap)

    if is_integer(value) and is_integer(limit) and value > limit do
      raise ArgumentError, "#{key} (#{value}) must not be higher than #{cap} (#{limit})"
    end

    :ok
  end

  def relation!({:at_least, key, floor}, opts) do
    value = Map.get(opts, key)
    limit = Map.get(opts, floor)

    if is_integer(value) and is_integer(limit) and value < limit do
      raise ArgumentError, "#{key} (#{value}) must not be lower than #{floor} (#{limit})"
    end

    :ok
  end

  # The check of a value in the words of the guide: the first words of the
  # cell "Check at boot" of the option.
  #
  @spec describe(OzMcp.Instance.Config.Schema.row()) :: String.t()
  def describe({_key, :pos_int, _default, flags}) do
    bound = if flags[:max], do: ", at most `#{flags[:max]}`", else: ""

    tails = [
      bound,
      flags[:null] && ", or `nil`",
      flags[:infinity] && ", or `:infinity`"
    ]

    Enum.reduce(tails, "positive integer", fn
      nil, acc -> acc
      tail, acc -> acc <> tail
    end)
  end

  def describe({_key, :non_neg_int, _default, _flags}), do: "non-negative integer"
  def describe({_key, :boolean, _default, _flags}), do: "`true` or `false`"
  def describe({_key, {:module, _label, _required}, _default, _flags}), do: "the functions"

  # -----
  # The four keys of the type `:custom`.
  # -----

  def custom(:allowed_origins, nil, _server), do: []

  def custom(:allowed_origins, allowed, _server) when is_list(allowed) do
    Enum.each(allowed, &origin!/1)
    allowed
  end

  def custom(:allowed_origins, allowed, _server),
    do: raise(ArgumentError, "allowed_origins must be a list, got: #{inspect(allowed)}")

  def custom(:allowed_hosts, nil, _server), do: :any
  def custom(:allowed_hosts, :any, _server), do: :any

  def custom(:allowed_hosts, hosts, _server) when is_list(hosts) do
    Enum.map(hosts, &host!/1)
  end

  def custom(:allowed_hosts, hosts, _server) do
    raise ArgumentError,
          "allowed_hosts must be :any or a list of host names, got: #{inspect(hosts)}"
  end

  # A prefix that two instances share is valid: the metadata `:instance`
  # tells their events apart. `nil` is refused.
  #
  def custom(:telemetry_prefix, [_ | _] = prefix, _server) do
    if Enum.all?(prefix, &is_atom/1) do
      prefix
    else
      raise ArgumentError,
            "telemetry_prefix must be a non-empty list of atoms, got: #{inspect(prefix)}"
    end
  end

  def custom(:telemetry_prefix, other, _server) do
    raise ArgumentError,
          "telemetry_prefix must be a non-empty list of atoms, got: #{inspect(other)}"
  end

  # The check of `resource_url` depends on the transport and on the
  # authorization block of the server: it stays in the config.
  #
  def custom(:resource_url, value, _server), do: value

  defp origin!("*") do
    raise ArgumentError,
          ~s{allowed_origins: "*" is not a wildcard. Give each origin, } <>
            ~s{for example "https://app.example.com"}
  end

  defp origin!(origin) when is_binary(origin) and origin != "", do: :ok

  defp origin!(origin) do
    raise ArgumentError, "allowed_origins must hold non-empty strings, got: #{inspect(origin)}"
  end

  # The boot lower-cases the hosts, so a host in the `Host` header
  # compares without its case.
  #
  defp host!(host) when is_binary(host) and host != "", do: String.downcase(host)

  defp host!(host) do
    raise ArgumentError, "allowed_hosts must hold non-empty strings, got: #{inspect(host)}"
  end

  defp describe_pos(flags) do
    unit = if flags[:unit], do: " (#{flags[:unit]})", else: ""
    bound = if flags[:max], do: " at most #{flags[:max]}", else: ""

    tail =
      Enum.join(
        Enum.reject([flags[:null] && " or nil", flags[:infinity] && " or :infinity"], &is_nil/1)
      )

    "a positive integer" <> unit <> bound <> tail
  end

  defp within_max?(value, flags), do: is_nil(flags[:max]) or value <= flags[:max]
end
