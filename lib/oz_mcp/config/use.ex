#
# The options are checked here, before the `use` of the DSL module: the
# `__before_compile__` of the DSL runs first and refuses the functions of
# a module with `dsl?: false`, so a later check never gives its message.
#
defmodule OzMcp.Config.Use do
  @moduledoc false

  @base [dsl?: true, warn?: true]

  @spec using(module(), Macro.Env.t(), keyword(), keyword()) :: Macro.t()
  def using(kind, caller, opts, extra \\ []) do
    options = check!(kind, caller.module, opts, @base ++ extra)

    dsl_ast =
      if options.dsl? do
        quote do: use(unquote(Module.concat(kind, DSL)), unquote(Map.to_list(options)))
      end

    quote do
      unquote(dsl_ast)
      @behaviour unquote(kind)
      Module.register_attribute(__MODULE__, :__options__, [])
      Module.put_attribute(__MODULE__, :__options__, unquote(Macro.escape(options)))
      @before_compile unquote(kind)
    end
  end

  @spec before_compile(Macro.Env.t(), {atom(), arity()}, (map() -> Macro.t())) :: Macro.t()
  def before_compile(env, callback, extra_fun \\ fn _options -> nil end) do
    for {name, arity} = function <- [{:list, 0}, callback],
        not Module.defines?(env.module, function) do
      raise RuntimeError, "you must satisfy the #{name}/#{arity} behaviour"
    end

    options = Module.get_attribute(env.module, :__options__)
    Module.delete_attribute(env.module, :__options__)
    extra_fun.(options)
  end

  defp check!(kind, module, opts, defaults) do
    allowed = Keyword.keys(defaults)

    for {key, _value} <- opts, key not in allowed do
      raise ArgumentError,
            "#{inspect(module)}: unknown option #{inspect(key)} for use #{inspect(kind)}, " <>
              "the options are: #{inspect(allowed)}"
    end

    options = Map.new(defaults, fn {key, default} -> {key, Keyword.get(opts, key, default)} end)

    for {key, _default} <- defaults, not is_boolean(options[key]) do
      raise ArgumentError, "#{key} option must be a boolean"
    end

    options
  end
end
