#
# Runtime checks that the DSL core calls, in one place.
#
defmodule OzMcp.Config.DSL.Checks do
  @moduledoc false

  alias OzMcp.Config.DSL.Rules

  # The key of a `meta` or `extra` entry: a string, or an atom that becomes
  # a string. `nil`, `true` and `false` are values, not names.
  #
  @spec meta_key!(term()) :: String.t()
  def meta_key!(key) when is_binary(key), do: key

  def meta_key!(key) when is_atom(key) and key not in [nil, true, false],
    do: Atom.to_string(key)

  def meta_key!(key) do
    raise ArgumentError, "'key' must be a string, got: #{inspect(key)}"
  end

  # The key of a `meta` entry and a valid `_meta` key of the specification.
  # A bad key raises an `ArgumentError`.
  #
  @spec meta_block_key!(term()) :: String.t()
  def meta_block_key!(key) do
    key = meta_key!(key)

    case Rules.meta_key(key) do
      :ok -> key
      {:error, message} -> raise ArgumentError, message
    end
  end

  # The key of a `meta` entry at `path`: the rule of `meta_block_key!/1`.
  #
  @spec meta_pair_key!(list(atom()), term()) :: String.t()
  def meta_pair_key!(_path, key), do: meta_block_key!(key)

  # The key of an `extra` entry at `path` and not a field of the result.
  #
  @spec extra_pair_key!(list(atom()), term()) :: String.t()
  def extra_pair_key!(path, key), do: extra_key!(path, meta_key!(key))

  # The value of a `meta` or `extra` entry. Booleans and `nil` stay; the
  # other atoms become strings.
  #
  @spec meta_value(term()) :: term()
  def meta_value(value) when is_boolean(value) or is_nil(value), do: value
  def meta_value(value) when is_atom(value), do: Atom.to_string(value)
  def meta_value(value), do: value

  # An extra with one of the fields of its result would make a second key
  # with the same name.
  #
  @reserved_extra_keys %{
    [] => ~w(_meta protocolVersion capabilities serverInfo instructions),
    [:tools, :list_result] => ~w(_meta tools nextCursor),
    [:resources, :list_result] => ~w(_meta resources nextCursor),
    [:templates, :list_result] => ~w(_meta resourceTemplates nextCursor),
    [:prompts, :list_result] => ~w(_meta prompts nextCursor)
  }

  # Refuses an entity whose key is already declared. `label` names the key
  # in the error message.
  #
  @spec unique!(list(map()), map(), atom(), String.t()) :: :ok
  def unique!(declared, entity, field, label) do
    key = Map.fetch!(entity, field)

    if Enum.any?(declared, &(Map.fetch!(&1, field) == key)) do
      raise ArgumentError, "duplicate #{label}: #{inspect(key)} is declared two times"
    end

    :ok
  end

  # Refuses a module that a block of the server lists two times.
  #
  @spec unique_module!(list(module()), module(), atom()) :: :ok
  def unique_module!(modules, module, block) do
    if module in modules do
      raise ArgumentError, "module #{inspect(module)} is listed two times in '#{block}'"
    end

    :ok
  end

  # The data of an icon block. An icon with no `src` stops the compilation.
  #
  @spec icon!(map()) :: map()
  def icon!(%{src: ""}), do: raise("icon 'src' is required")
  def icon!(icon), do: icon

  # The data of a block that must have at least one of `fields`.
  #
  @spec not_empty!(map(), [atom()], String.t()) :: map()
  def not_empty!(data, fields, block) do
    if Enum.all?(fields, &is_nil(Map.fetch!(data, &1))) do
      raise "remove '#{block}', it's empty"
    end

    data
  end

  # The data of a registry block of the server, which needs one module.
  #
  @spec modules!(map(), String.t()) :: map()
  def modules!(%{modules: [_ | _]} = data, _entity), do: data
  def modules!(_data, entity), do: raise("must declare at least one #{entity}")

  # Checks that the field `field` of an entity is not `""` and not `nil`.
  #
  @spec required!(map(), module(), atom(), String.t()) :: :ok
  def required!(data, _module, field, message) do
    if Map.fetch!(data, field) in ["", nil], do: raise(message)
    :ok
  end

  # Checks that each key of an `experimental` map is a string or an atom.
  #
  @spec experimental_keys!(map()) :: :ok
  def experimental_keys!(value) do
    if not Enum.all?(Map.keys(value), &(is_binary(&1) or is_atom(&1))) do
      raise ArgumentError, "all keys of 'experimental' map must be a string or atom"
    end

    :ok
  end

  # Refuses an `extra` key that is a field of the result of the block.
  #
  @spec extra_key!(list(atom()), String.t()) :: String.t()
  def extra_key!(path, key) do
    if key in Map.get(@reserved_extra_keys, path, []) do
      raise ArgumentError,
            "'extra' key #{inspect(key)} is a field of the result, " <>
              "use the field (or 'meta' for \"_meta\")"
    end

    key
  end
end
