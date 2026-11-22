#
# Writes the thin macros of a DSL module from the tables of the module.
#
# Call it after the attributes @properties, @blocks and @pairs and
# the optional @entity and @extra_qualify.
#
# The compiler expands the body of a module before it evaluates the
# module attributes, so the macro defers the read of the tables to the
# evaluation of `__define__/1`.
#
defmodule OzMcp.Config.DSL.Generate do
  @moduledoc false

  alias OzMcp.Config.DSL.{Core, Entity, Qualify}

  defmacro macros do
    quote do
      OzMcp.Config.DSL.Generate.__define__(__MODULE__)
    end
  end

  @spec __define__(module()) :: :ok
  def __define__(module) do
    properties = Module.get_attribute(module, :properties) || %{}
    blocks = Module.get_attribute(module, :blocks) || %{}
    pairs = Module.get_attribute(module, :pairs) || %{}
    entity = Module.get_attribute(module, :entity)
    extra = Module.get_attribute(module, :extra_qualify) || []

    qualify =
      Enum.map(Map.keys(properties) ++ Map.keys(blocks), &{&1, 1}) ++
        Enum.map(Map.keys(pairs), &{&1, 2}) ++ extra

    ast =
      quote do
        @doc false
        def __property__(name), do: Map.fetch!(@properties, name)

        @doc false
        def __block_spec__(name), do: Map.fetch!(@blocks, name)

        @doc false
        def __pair__(name), do: Map.fetch!(@pairs, name)

        @doc false
        def __qualify__, do: unquote(qualify)

        unquote_splicing(Enum.map(Map.keys(properties), &property_macro/1))
        unquote_splicing(Enum.map(Map.keys(blocks), &block_macro/1))
        unquote_splicing(Enum.map(Map.keys(pairs), &pair_macro/1))
        unquote(entity_macros(entity))
      end

    _ = Code.eval_quoted(ast, [], module: module)
    :ok
  end

  defp property_macro(name) do
    quote do
      defmacro unquote(name)(value) do
        OzMcp.Config.DSL.Generate.property_call(__MODULE__, unquote(name), value)
      end
    end
  end

  defp block_macro(name) do
    quote do
      defmacro unquote(name)(do: block) do
        OzMcp.Config.DSL.Generate.block_call(__MODULE__, unquote(name), block)
      end
    end
  end

  defp pair_macro(name) do
    quote do
      defmacro unquote(name)(key, value) do
        OzMcp.Config.DSL.Generate.pair_call(__MODULE__, unquote(name), key, value)
      end
    end
  end

  defp entity_macros(nil), do: nil

  defp entity_macros(%{name: name}) do
    quote do
      @doc false
      def __entity__, do: @entity

      defmacro unquote(name)(entity_name, do: block) do
        OzMcp.Config.DSL.Generate.entity_call(__MODULE__, entity_name, block)
      end

      defmacro __using__(opts) do
        OzMcp.Config.DSL.Generate.using_call(__MODULE__, unquote(name), opts)
      end

      defmacro __before_compile__(env) do
        OzMcp.Config.DSL.Entity.before_compile(env, __MODULE__)
      end
    end
  end

  # ---------- The bodies of the macros

  @spec property_call(module(), atom(), Macro.t()) :: Macro.t()
  def property_call(dsl, name, value) do
    quote do
      unquote(Core).put_property(__MODULE__, unquote(dsl), unquote(name), unquote(value))
    end
  end

  @spec pair_call(module(), atom(), Macro.t(), Macro.t()) :: Macro.t()
  def pair_call(dsl, name, key, value) do
    quote do
      unquote(Core).put_pair(
        __MODULE__,
        unquote(dsl),
        unquote(name),
        unquote(key),
        unquote(value)
      )
    end
  end

  @spec block_call(module(), atom(), Macro.t()) :: Macro.t()
  def block_call(dsl, name, block) do
    block = Qualify.statements(block, dsl, dsl.__qualify__())

    quote do
      unquote(Core).open_block(__MODULE__, unquote(dsl), unquote(name))
      unquote(block)
      unquote(Core).close_block(__MODULE__, unquote(dsl), unquote(name))
    end
  end

  @spec entity_call(module(), Macro.t(), Macro.t()) :: Macro.t()
  def entity_call(dsl, name, block) do
    block = Qualify.statements(block, dsl, dsl.__qualify__())

    quote do
      unquote(Entity).open(
        __MODULE__,
        unquote(dsl),
        unquote(name),
        Macro.Env.stacktrace(__ENV__)
      )

      unquote(block)

      unquote(Entity).close(__MODULE__, unquote(dsl), Macro.Env.stacktrace(__ENV__))
    end
  end

  @spec using_call(module(), atom(), Macro.t()) :: Macro.t()
  def using_call(dsl, name, opts) do
    quote do
      import unquote(dsl), only: [{unquote(name), 2}]
      unquote(Entity).setup(__MODULE__, unquote(opts))
      @before_compile unquote(dsl)
    end
  end
end
