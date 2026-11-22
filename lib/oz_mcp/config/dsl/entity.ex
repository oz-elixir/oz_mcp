#
# The shared root block of a DSL that declares entities (`tool`,
# `prompt`, `resource` and `template`), its warnings and the
# `__before_compile__` callback of the module.
#
# The generator `OzMcp.Config.DSL.Generate` writes the macros that call
# these plain functions. The functions run in the body of the user
# module, at compile time.
#
# The row `@entity` of a DSL module holds:
#
#   name        the macro and the path (:tool)
#   struct      the struct of the entity
#   key         the field that is unique in the module
#   label       the name of this key in the error message
#   use         the module in the text of the warnings
#   check_name  hook (module, name, stacktrace) before the block; optional
#   finish      hook (data, module) after the block; optional
#   accepted    hook (data, module) after the check of the key; optional
#
defmodule OzMcp.Config.DSL.Entity do
  @moduledoc false

  alias OzMcp.Config.DSL.{Checks, Core}

  @spec setup(module(), keyword()) :: :ok
  def setup(module, opts) do
    Module.put_attribute(module, :__warn__, Keyword.get(opts, :warn?, true))
    Module.put_attribute(module, :__strict_names__, Keyword.get(opts, :strict_names?, false))
    Module.put_attribute(module, :__compiled__, [])
    Core.init(module, [])
  end

  @spec open(module(), module(), term(), Exception.stacktrace()) :: :ok
  def open(module, dsl, name, stacktrace) do
    spec = dsl.__entity__()

    if not is_binary(name) do
      raise ArgumentError, "name must be a string, got: #{inspect(name)}"
    end

    if name == "" do
      raise ArgumentError, "'name' cannot be an empty string"
    end

    run(spec[:check_name], [module, name, stacktrace])

    if Module.get_attribute(module, :__path__) != [] do
      raise "cannot use '#{spec.name}' here"
    end

    Core.enter(module, [spec.name], struct(spec.struct, name: name))
  end

  @spec close(module(), module(), Exception.stacktrace()) :: :ok
  def close(module, dsl, stacktrace) do
    spec = dsl.__entity__()
    data = Core.read(module, [spec.name])

    run(spec[:finish], [data, module])
    warn_missing(module, spec, data, :title, stacktrace)
    warn_missing(module, spec, data, :description, stacktrace)

    config = Module.get_attribute(module, :__config__)
    Checks.unique!(config, data, spec.key, spec.label)
    run(spec[:accepted], [data, module])

    Module.put_attribute(module, :__config__, config ++ [data])
    Module.put_attribute(module, :__path__, [])
    :ok
  end

  @spec before_compile(Macro.Env.t(), module()) :: Macro.t()
  def before_compile(env, dsl) do
    spec = dsl.__entity__()
    module = env.module
    config = Module.get_attribute(module, :__config__)
    compiled = Module.get_attribute(module, :__compiled__)

    for attribute <-
          [:__warn__, :__strict_names__, :__path__, :__cache__] ++
            [:__defined__, :__compiled__] do
      Module.delete_attribute(module, attribute)
    end

    for {name, arity} = function <- [list: 0],
        Module.defines?(module, function) do
      raise "when using the #{spec.name} DSL you can't declare #{name}/#{arity} function"
    end

    if config == [] do
      raise "you must at least define one #{spec.name}"
    end

    catalog = catalog(config, spec.key, compiled)

    quote do
      def list, do: @__config__

      @doc false
      def __catalog__, do: unquote(Macro.escape(catalog))
    end
  end

  # ---------- Private

  defp run(nil, _args), do: :ok
  defp run({module, function, args}, first), do: apply(module, function, first ++ args)

  defp catalog(config, key, []) do
    Enum.map(config, &%OzMcp.Catalog.Entry{key: Map.fetch!(&1, key), entity: &1})
  end

  defp catalog(config, key, compiled) do
    config
    |> Enum.zip(compiled)
    |> Enum.map(fn {entity, matcher} ->
      %OzMcp.Catalog.Entry{key: Map.fetch!(entity, key), entity: entity, matcher: matcher}
    end)
  end

  defp warn_missing(module, spec, data, field, stacktrace) do
    if Module.get_attribute(module, :__warn__) and is_nil(Map.fetch!(data, field)) do
      IO.warn(missing_message(spec, data.name, field), stacktrace)
    end
  end

  defp missing_message(spec, name, field) do
    """
    The #{spec.name} #{name} does not have a #{field} configuration

    - MCP specification say that the #{field} is optional.
    - But it's a bad practice to omitting it.
    - It will not help LLM to understand the #{spec.name}.

    Add:

    #{spec.name} "#{name}" do
      #{field} "the #{spec.name} #{field}"
    end

    To disable warnings:

    use #{spec.use}, warn?: false
    """
  end
end
