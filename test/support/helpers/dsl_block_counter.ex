defmodule Support.Helpers.DslBlockCounter do
  def bump(tag) do
    key = {:dsl_block_expansion, tag}
    Process.put(key, (Process.get(key) || 0) + 1)
    :ok
  end

  def read(tag) do
    Process.get({:dsl_block_expansion, tag}) || 0
  end
end
