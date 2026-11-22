defmodule OzMcp.Config.DSL.Qualify do
  @moduledoc false

  @block_keys [:do, :else, :catch, :rescue, :after]

  @spec statements(Macro.t(), module(), [{atom(), non_neg_integer()}]) :: Macro.t()
  def statements({:__block__, meta, stmts}, module, names) do
    {:__block__, meta, Enum.map(stmts, &statement(&1, module, names))}
  end

  def statements(stmt, module, names), do: statement(stmt, module, names)

  defp statement({:__block__, _meta, _stmts} = block, module, names) do
    statements(block, module, names)
  end

  defp statement({name, meta, args}, module, names) when is_atom(name) and is_list(args) do
    args = do_blocks(args, module, names)

    if {name, length(args)} in names do
      {{:., meta, [module, name]}, meta, args}
    else
      {name, meta, args}
    end
  end

  defp statement(other, _module, _names), do: other

  # The last argument holds the block keys with the nested statements. The
  # other keys of the list are values, so the helper leaves them as they are.
  #
  defp do_blocks(args, module, names) do
    last = List.last(args)

    if Keyword.keyword?(last) and Keyword.has_key?(last, :do) do
      nested =
        Enum.map(last, fn
          {key, body} when key in @block_keys -> {key, body(body, module, names)}
          other -> other
        end)

      List.replace_at(args, -1, nested)
    else
      args
    end
  end

  defp body(clauses, module, names) when is_list(clauses) do
    Enum.map(clauses, fn
      {:->, meta, [head, body]} -> {:->, meta, [head, statements(body, module, names)]}
      other -> other
    end)
  end

  defp body(block, module, names), do: statements(block, module, names)
end
