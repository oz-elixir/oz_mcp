defmodule OzMcp.Structs.Wire.Field do
  @moduledoc false

  @enforce_keys [:key, :setter, :kind]
  defstruct [
    :key,
    :setter,
    :kind,
    :default,
    :also,
    :check,
    :emit,
    :to,
    :item,
    :type,
    required: false,
    absolute: true
  ]

  @kinds [
    :string,
    :any_string,
    :uri,
    :non_neg_integer,
    :number,
    :boolean,
    :map,
    :list,
    :content_list,
    :task,
    :meta,
    :extras,
    :scopes,
    :any
  ]

  @options [:required, :default, :also, :check, :emit, :to, :item, :setter, :type, :absolute]

  @spec normalize({atom(), term()}) :: %__MODULE__{}
  def normalize({key, {kind, opts}})
      when is_atom(kind) and is_list(opts) and kind in @kinds,
      do: build(key, kind, opts)

  def normalize({key, {kind, opts}}) when is_list(opts) and not is_atom(kind),
    do: build(key, kind, opts)

  def normalize({key, kind}), do: build(key, kind, [])

  defp build(key, kind, opts) do
    check_kind!(key, kind)
    opts = Keyword.validate!(opts, @options)
    check_absolute!(key, kind, opts)
    required = Keyword.get(opts, :required, kind in [:uri, :task, :content_list])

    %__MODULE__{
      key: key,
      setter: setter(key, opts),
      kind: kind,
      required: required,
      default: Keyword.get_lazy(opts, :default, fn -> default(kind, required) end),
      also: Keyword.get(opts, :also),
      check: Keyword.get(opts, :check),
      emit: Keyword.get_lazy(opts, :emit, fn -> emit(kind, required) end),
      to: Keyword.get(opts, :to),
      item: Keyword.get(opts, :item),
      type: Keyword.get(opts, :type),
      absolute: Keyword.get(opts, :absolute, true)
    }
  end

  defp setter(key, opts) do
    case Keyword.get(opts, :setter, true) do
      false -> nil
      true -> key |> Atom.to_string() |> Macro.underscore() |> String.to_atom()
    end
  end

  defp default(kind, true) when kind in [:string, :uri], do: ""
  defp default(:list, true), do: []
  defp default(:map, true), do: %{}
  defp default({:maps_of, _module}, _required), do: []
  defp default(:content_list, _required), do: []
  defp default(:scopes, _required), do: []
  defp default(_kind, _required), do: nil

  defp emit(:scopes, _required), do: :never
  defp emit(_kind, true), do: :always
  defp emit(_kind, false), do: :present

  defp check_kind!(_key, kind) when kind in @kinds, do: :ok
  defp check_kind!(_key, {:between, _min, _max}), do: :ok
  defp check_kind!(_key, {:one_of, values}) when is_list(values), do: :ok

  defp check_kind!(_key, {tag, module})
       when tag in [:struct, :list_of, :maps_of] and is_atom(module),
       do: :ok

  defp check_kind!(key, kind) do
    raise ArgumentError, "unknown kind #{inspect(kind)} for field #{inspect(key)}"
  end

  defp check_absolute!(key, kind, opts) do
    if kind != :uri and Keyword.has_key?(opts, :absolute) do
      raise ArgumentError, "the 'absolute' option is for a 'uri' field, got on #{inspect(key)}"
    end
  end
end
