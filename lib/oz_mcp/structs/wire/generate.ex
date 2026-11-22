defmodule OzMcp.Structs.Wire.Generate do
  @moduledoc false

  alias OzMcp.Structs.Wire.Doc

  @spec code([struct()], keyword()) :: Macro.t()
  def code(fields, opts) do
    quote do
      unquote(moduledoc(fields))

      @type t() :: %__MODULE__{unquote_splicing(types(fields))}

      defstruct unquote(Macro.escape(Enum.map(fields, &{&1.key, &1.default})))

      unquote_splicing(setters(fields))

      unquote(build(fields, opts))

      @doc false
      def __fields__, do: unquote(Macro.escape(wire_keys(fields, opts)))
    end
  end

  defp moduledoc(fields) do
    table = Doc.table(fields)

    quote do
      doc = @moduledoc
      Module.delete_attribute(__MODULE__, :moduledoc)
      @moduledoc Kernel.<>(doc || "", unquote(table))
    end
  end

  defp types(fields) do
    Enum.map(fields, fn field -> {field.key, type_of(field)} end)
  end

  defp setters(fields) do
    for field <- fields, field.setter != nil do
      setter(field)
    end
  end

  defp setter(%{kind: :scopes} = field) do
    quote do
      @spec unquote(field.setter)(t(), unquote(type_of(field))) :: t()
      def unquote(field.setter)(struct, value) do
        Map.put(struct, unquote(field.key), OzMcp.Auth.Scopes.check!(value))
      end
    end
  end

  defp setter(field) do
    quote do
      @spec unquote(field.setter)(t(), unquote(type_of(field))) :: t()
      def unquote(field.setter)(struct, value) do
        Map.put(struct, unquote(field.key), value)
      end
    end
  end

  defp build(fields, opts) do
    if Keyword.get(opts, :build, true) do
      struct_var = Macro.var(:struct, __MODULE__)
      result = Macro.var(:result, __MODULE__)
      const = Macro.escape(Keyword.get(opts, :const, %{}))
      checks = Enum.flat_map(fields, &checks(&1, struct_var))
      {extras, normal} = Enum.split_with(fields, &(&1.kind == :extras))
      emits = Enum.flat_map(normal, &emit(&1, result, struct_var))

      merges =
        for _field <- extras do
          quote do
            unquote(result) =
              OzMcp.Structs.Builder.maybe_extras(unquote(result), unquote(struct_var))
          end
        end

      quote do
        @spec build(t()) :: map()
        def build(unquote(struct_var)) do
          unquote_splicing(checks)
          unquote(result) = unquote(const)
          unquote_splicing(emits)
          unquote_splicing(merges)
          unquote(result)
        end

        defoverridable build: 1
      end
    end
  end

  defp checks(field, struct_var) do
    value = quote do: unquote(struct_var).unquote(field.key)

    base =
      case field.check do
        nil -> kind_checks(field, value)
        name -> [quote(do: unquote(name)(unquote(value)))]
      end

    base ++ also(field, value)
  end

  defp also(%{also: nil}, _value), do: []

  defp also(%{also: name, key: key}, value) do
    [validate(name, [key, value])]
  end

  defp kind_checks(%{kind: :string, required: true} = field, value) do
    [validate(:non_empty_string, [field.key, value])]
  end

  defp kind_checks(%{kind: :string} = field, value) do
    [validate(:non_empty_string_or_nil, [field.key, value])]
  end

  defp kind_checks(%{kind: :any_string} = field, value) do
    [validate(:string_or_nil, [field.key, value])]
  end

  defp kind_checks(%{kind: :uri, required: true, absolute: true} = field, value) do
    [validate(:non_empty_string, [field.key, value]), validate(:absolute_uri, [field.key, value])]
  end

  defp kind_checks(%{kind: :uri, required: true} = field, value) do
    [validate(:non_empty_string, [field.key, value])]
  end

  defp kind_checks(%{kind: :uri}, _value), do: []

  defp kind_checks(%{kind: :non_neg_integer} = field, value) do
    [validate(:non_neg_integer_or_nil, [field.key, value])]
  end

  defp kind_checks(%{kind: :number} = field, value) do
    [validate(:number_or_nil, [field.key, value])]
  end

  defp kind_checks(%{kind: {:between, min, max}} = field, value) do
    [validate(:number_between_or_nil, [field.key, value, min, max])]
  end

  defp kind_checks(%{kind: :boolean} = field, value) do
    [validate(:boolean_or_nil, [field.key, value])]
  end

  defp kind_checks(%{kind: :map, required: true} = field, value) do
    [validate(:map, [field.key, value])]
  end

  defp kind_checks(%{kind: :map} = field, value) do
    [validate(:map_or_nil, [field.key, value])]
  end

  defp kind_checks(%{kind: :list, required: true} = field, value) do
    [validate(:list, [field.key, value])]
  end

  defp kind_checks(%{kind: :list} = field, value) do
    [validate(:list_or_nil, [field.key, value])]
  end

  defp kind_checks(%{kind: {:one_of, values}, required: true} = field, value) do
    [validate(:one_of, [field.key, value, Macro.escape(values)])]
  end

  defp kind_checks(%{kind: {:one_of, values}} = field, value) do
    [validate(:one_of_or_nil, [field.key, value, Macro.escape(values)])]
  end

  defp kind_checks(%{kind: {:struct, module}, required: true} = field, value) do
    [validate(:struct, [field.key, module, value])]
  end

  defp kind_checks(%{kind: {:struct, module}} = field, value) do
    [validate(:struct_or_nil, [field.key, module, value])]
  end

  defp kind_checks(%{kind: {:list_of, _module}, required: true} = field, value) do
    [validate(:list, [field.key, value])]
  end

  defp kind_checks(%{kind: {:list_of, _module}} = field, value) do
    [validate(:list_or_nil, [field.key, value])]
  end

  defp kind_checks(%{kind: {:maps_of, _module}, required: true} = field, value) do
    [validate(:list, [field.key, value])]
  end

  defp kind_checks(%{kind: {:maps_of, _module}} = field, value) do
    [validate(:list_or_nil, [field.key, value])]
  end

  defp kind_checks(%{kind: :content_list, required: true} = field, value) do
    [
      validate(:list, [field.key, value]),
      quote do
        Enum.each(unquote(value), &OzMcp.Structs.Validate.content/1)
      end
    ]
  end

  defp kind_checks(%{kind: :content_list}, _value), do: []

  defp kind_checks(%{kind: :task}, value) do
    [quote(do: OzMcp.Structs.Validate.task(unquote(value)))]
  end

  defp kind_checks(%{kind: :meta} = field, value) do
    [validate(:meta, [field.key, value])]
  end

  defp kind_checks(%{kind: :extras} = field, value) do
    [validate(:map_or_nil, [field.key, value])]
  end

  defp kind_checks(_field, _value), do: []

  defp validate(fun, args) do
    quote do
      OzMcp.Structs.Validate.unquote(fun)(unquote_splicing(args))
    end
  end

  defp emit(%{emit: :never}, _result, _struct_var), do: []

  defp emit(field, result, struct_var) do
    value = quote do: unquote(struct_var).unquote(field.key)
    [quote(do: unquote(result) = unquote(emit_value(field.emit, field, result, value)))]
  end

  defp emit_value(:always, field, result, value), do: put(result, field, value)

  defp emit_value(:present, field, result, value) do
    present = Macro.var(:present, __MODULE__)

    quote do
      case unquote(value) do
        nil -> unquote(result)
        unquote(present) -> unquote(put(result, field, present))
      end
    end
  end

  defp emit_value(:true_only, field, result, value) do
    quote do
      if unquote(value) == true do
        unquote(put(result, field, value))
      else
        unquote(result)
      end
    end
  end

  defp put(result, field, value) do
    value = if field.to == :string, do: quote(do: to_string(unquote(value))), else: value

    quote do
      Map.put(unquote(result), unquote(field.key), unquote(transform(field, value)))
    end
  end

  defp transform(%{item: item}, value) when item != nil do
    quote do
      Enum.map(unquote(value), fn item -> unquote(item)(item) end)
    end
  end

  defp transform(%{kind: {:list_of, module}}, value) do
    quote do
      Enum.map(unquote(value), fn item -> unquote(module).build(item) end)
    end
  end

  defp transform(%{kind: {:maps_of, module}}, value) do
    quote do
      Enum.map(unquote(value), fn
        %unquote(module){} = item ->
          unquote(module).build(item)

        item when is_map(item) ->
          item

        item ->
          raise ArgumentError, "each item must be a map, got: #{inspect(item)}"
      end)
    end
  end

  defp transform(%{kind: :content_list}, value) do
    quote do
      Enum.map(unquote(value), &OzMcp.Structs.Builder.content/1)
    end
  end

  defp transform(%{kind: :task}, value) do
    quote do: OzMcp.Structs.Task.build(unquote(value))
  end

  defp transform(%{kind: {:struct, module}}, value) do
    quote do: unquote(module).build(unquote(value))
  end

  defp transform(_field, value), do: value

  defp type_of(%{type: type}) when type != nil, do: type

  defp type_of(%{kind: kind, default: default}) do
    type = kind_type(kind)
    if is_nil(default), do: quote(do: unquote(type) | nil), else: type
  end

  defp kind_type(:string), do: quote(do: String.t())
  defp kind_type(:any_string), do: quote(do: String.t())
  defp kind_type(:uri), do: quote(do: String.t())
  defp kind_type(:non_neg_integer), do: quote(do: non_neg_integer())
  defp kind_type(:number), do: quote(do: number())
  defp kind_type({:between, _min, _max}), do: quote(do: number())
  defp kind_type(:boolean), do: quote(do: boolean())
  defp kind_type(:map), do: quote(do: map())
  defp kind_type(:meta), do: quote(do: map())
  defp kind_type(:extras), do: quote(do: map())
  defp kind_type(:list), do: quote(do: list())
  defp kind_type({:one_of, _values}), do: quote(do: term())
  defp kind_type({:struct, module}), do: quote(do: unquote(module).t())
  defp kind_type({:list_of, module}), do: quote(do: [unquote(module).t()])
  defp kind_type({:maps_of, module}), do: quote(do: [unquote(module).t() | map()])
  defp kind_type(:content_list), do: quote(do: [OzMcp.Structs.ContentBlock.t()])
  defp kind_type(:task), do: quote(do: OzMcp.Structs.Task.t())
  defp kind_type(:scopes), do: quote(do: [String.t()])
  defp kind_type(_kind), do: quote(do: term())

  defp wire_keys(fields, opts) do
    field_keys =
      fields
      |> Enum.reject(&(&1.emit == :never or &1.key == :extras))
      |> Enum.map(& &1.key)

    const_keys = opts |> Keyword.get(:const, %{}) |> Map.keys()

    Enum.uniq(field_keys ++ const_keys)
  end
end
