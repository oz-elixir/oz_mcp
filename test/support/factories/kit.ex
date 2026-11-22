#
# The parts that the five DSL factories share: the drivers, the block
# macros and the property helpers. A factory writes `use Support.Factories.Kit`,
# then declares its blocks with `block/2` and its properties with
# `props/1`.
#
defmodule Support.Factories.Kit do
  defmacro __using__(_opts) do
    quote do
      import ExUnit.Assertions

      alias Support.Helpers.Utils

      import Support.Factories.Kit,
        only: [block: 2, props: 1, code: 1, has_call?: 2, has_def?: 2, use_line: 2]

      def source(ast), do: Macro.to_string(ast)

      def compile(ast) do
        [{mod, _bin}] = Code.compile_quoted(ast)
        mod
      end

      def assert_compile_raise(ast, error, message, output) do
        io_output =
          Utils.capture_diagnostics(fn ->
            assert_raise(error, message, fn -> compile(ast) end)
          end)

        assert io_output =~ output
      end

      def assert_compile_raise(ast, error, message) do
        assert_raise(error, message, fn -> compile(ast) end)
      end

      def assert_compile_warning(ast, output) do
        assert Utils.capture_diagnostics(fn -> compile(ast) end) =~ output
      end

      def refute_compile_warning(ast, outputs) do
        io_output = Utils.capture_diagnostics(fn -> compile(ast) end)
        Enum.each(outputs, fn output -> refute io_output =~ output end)
      end
    end
  end

  # Defines the macros of the block `name`. With `named: true` the block
  # takes a name first (`tool "x" do ... end`). With `lines: specs` it also
  # defines `__name__/2` (or `/3`): each `{key, default}` of the specs
  # adds `key(value)` to the block, unless the value is `:_none_`. A
  # default `{:required, value}` is skipped when the block already calls
  # `key`. With `body: :raw` the block is built with no `__block__` around
  # one expression. With `as: call` the block calls `call` (the macro
  # `cap_resources` of the server factory builds `resources do ... end`).
  #

  defmacro block(name, opts) do
    named? = Keyword.get(opts, :named, false)
    specs = Keyword.get(opts, :lines, :custom)
    raw? = Keyword.get(opts, :body) == :raw
    as = Keyword.get(opts, :as, name)
    fun = :"__#{name}__"

    macros =
      if named? do
        quote do
          defmacro unquote(name)(name, opts \\ []) do
            {block, kw} = Keyword.pop(opts, :do)
            Support.Factories.Kit.build(__MODULE__, unquote(fun), [name], kw, block)
          end

          defmacro unquote(name)(name, opts, do: block) do
            Support.Factories.Kit.build(__MODULE__, unquote(fun), [name], opts, block)
          end
        end
      else
        quote do
          defmacro unquote(name)(opts \\ []) do
            {block, kw} = Keyword.pop(opts, :do)
            Support.Factories.Kit.build(__MODULE__, unquote(fun), [], kw, block)
          end

          defmacro unquote(name)(opts, do: block) do
            Support.Factories.Kit.build(__MODULE__, unquote(fun), [], opts, block)
          end
        end
      end

    builder =
      cond do
        specs == :custom ->
          nil

        named? ->
          quote do
            @doc false
            def unquote(fun)(name, opts, exprs) do
              lines = Support.Factories.Kit.lines(__MODULE__, opts, unquote(specs), exprs)
              Support.Factories.Kit.node(unquote(as), [name], lines ++ exprs, unquote(raw?))
            end
          end

        true ->
          quote do
            @doc false
            def unquote(fun)(opts, exprs) do
              lines = Support.Factories.Kit.lines(__MODULE__, opts, unquote(specs), exprs)
              Support.Factories.Kit.node(unquote(as), [], lines ++ exprs, unquote(raw?))
            end
          end
      end

    [macros, builder]
  end

  # Defines one helper per property: `key(value)` gives the AST of the
  # call `key(value)`. The keys under `escaped:` escape their value.
  # `meta/2` and `extra/2` take a key and a value.
  #

  defmacro props(opts) do
    plain = Keyword.get(opts, :plain, [])
    escaped = Keyword.get(opts, :escaped, [])
    keyed = Keyword.get(opts, :keyed, [])

    one =
      for key <- plain do
        quote do
          def unquote(key)(value), do: {unquote(key), [], [value]}
        end
      end

    esc =
      for key <- escaped do
        quote do
          def unquote(key)(value), do: {unquote(key), [], [Macro.escape(value)]}
        end
      end

    two =
      for key <- keyed do
        quote do
          def unquote(key)(key, value), do: {unquote(key), [], [key, value]}
        end
      end

    one ++ esc ++ two
  end

  @doc false
  def build(mod, fun, args, kw, block) do
    exprs = to_expr_list(block)

    quote do
      unquote(mod).unquote(fun)(unquote_splicing(args), unquote(kw), [unquote_splicing(exprs)])
    end
  end

  @doc false
  def lines(mod, opts, specs, exprs) do
    Enum.flat_map(specs, fn
      {key, {:required, default}} ->
        value = Keyword.get(opts, key, default)
        if value == :_none_ or has_call?(exprs, key), do: [], else: [apply(mod, key, [value])]

      {key, default} ->
        case Keyword.get(opts, key, default) do
          :_none_ -> []
          value -> [apply(mod, key, [value])]
        end
    end)
  end

  @doc false
  def node(name, args, exprs, false), do: {name, [], args ++ [[do: {:__block__, [], exprs}]]}
  def node(name, args, [], true), do: {name, [], args ++ [[do: nil]]}
  def node(name, args, [single], true), do: {name, [], args ++ [[do: single]]}
  def node(name, args, exprs, true), do: {name, [], args ++ [[do: {:__block__, [], exprs}]]}

  # The code of a module, from the `_code_` option of `module`.
  #

  @doc false
  def code(opts) do
    case Keyword.get(opts, :_code_, :_none_) do
      :_none_ -> []
      c when is_list(c) -> c
      c -> to_expr_list(c)
    end
  end

  @doc false
  def unique(prefix, name) do
    Module.concat([prefix, name <> "_" <> to_string(System.unique_integer([:positive]))])
  end

  @doc false
  def use_opts(opts, keys) do
    for {key, opt} <- keys, (value = Keyword.get(opts, key, default(key))) != :_none_ do
      {opt, value}
    end
  end

  @doc false
  def use_line(dsl, []), do: quote(do: use(unquote(dsl)))
  def use_line(dsl, kw), do: quote(do: use(unquote(dsl), unquote(kw)))

  defp default(:_warn_), do: false
  defp default(_key), do: :_none_

  @doc false
  def to_expr_list({:__block__, _meta, exprs}), do: exprs
  def to_expr_list(nil), do: []
  def to_expr_list(expr), do: [expr]

  @doc false
  def has_call?(exprs, name) do
    Enum.any?(exprs, fn
      {^name, _, _} -> true
      _ -> false
    end)
  end

  @doc false
  def has_def?(exprs, name) do
    Enum.any?(exprs, fn
      {:def, _, [{^name, _, _} | _]} -> true
      _ -> false
    end)
  end
end
