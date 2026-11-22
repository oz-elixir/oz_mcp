#
# The plain functions that the generated macros call. They run in the
# body of the user module, at compile time.
#
#   __config__   the entities (a list), or the server config (a map)
#   __path__     the place of the current line, [] at the root
#   __cache__    path => the data of the open block
#   __defined__  path => the names declared in the open block
#
# One order for each line: the value, the place, the second declaration.
#
defmodule OzMcp.Config.DSL.Core do
  @moduledoc false

  alias OzMcp.Config.DSL.{Checks, Type}

  @spec init(module(), list() | map()) :: :ok
  def init(module, config) do
    Module.put_attribute(module, :__config__, config)
    Module.put_attribute(module, :__path__, [])
    Module.put_attribute(module, :__cache__, %{})
    Module.put_attribute(module, :__defined__, %{})
    :ok
  end

  # ---------- Property

  @spec put_property(module(), module(), atom(), term()) :: :ok
  def put_property(module, dsl, name, value) do
    spec = dsl.__property__(name)
    value = Type.check!(name, spec.type, value)
    path = place!(module, name, spec.paths)
    store(module, path, name, spec, value)
  end

  # A row with `append` adds one module to a registry block.
  #
  defp store(module, path, _name, %{append: block} = spec, value) do
    data = read(module, path)
    entries = Map.fetch!(data, spec.field)
    Checks.unique_module!(entries, value, block)
    write(module, path, Map.put(data, spec.field, entries ++ [value]))
  end

  defp store(module, path, name, spec, value) do
    declare_once!(module, path, name)
    write(module, path, Map.put(read(module, path), spec.field, value))
  end

  # ---------- Pair

  @spec put_pair(module(), module(), atom(), term(), term()) :: :ok
  def put_pair(module, dsl, name, key, value) do
    spec = dsl.__pair__(name)
    key = spec.key.(Module.get_attribute(module, :__path__), key)
    value = Checks.meta_value(value)
    path = place!(module, name, spec.paths)

    data = read(module, path)
    pairs = Map.fetch!(data, spec.field) || %{}

    if Map.has_key?(pairs, key) do
      raise "key '#{key}' already exists"
    end

    write(module, path, Map.put(data, spec.field, Map.put(pairs, key, value)))
  end

  # ---------- Block

  @spec open_block(module(), module(), atom()) :: :ok
  def open_block(module, dsl, name) do
    row = dsl.__block_spec__(name)
    path = place!(module, name, row.paths)
    spec = spec_at(row, path)

    if Map.get(spec, :mode, :once) == :once do
      declare_once!(module, path, name)
    end

    enter(module, path ++ [name], initial(spec.initial))
  end

  @spec close_block(module(), module(), atom()) :: :ok
  def close_block(module, dsl, name) do
    child_path = Module.get_attribute(module, :__path__)
    path = Enum.drop(child_path, -1)
    spec = spec_at(dsl.__block_spec__(name), path)

    child = finish(Map.get(spec, :finish), read(module, child_path))
    write(module, path, attach(read(module, path), child, spec))
    Module.put_attribute(module, :__path__, path)
    :ok
  end

  # ---------- The tools of the other modules

  # A step that does not fit a row, for example `argument/2` of a prompt.
  #
  @spec update(module(), atom(), [list(atom())], (map() -> map())) :: :ok
  def update(module, name, paths, fun) do
    path = place!(module, name, paths)
    write(module, path, fun.(read(module, path)))
  end

  # Opens a path. The marks of this path are cleared: two `icon` blocks,
  # or two `tool` blocks, have the same path.
  #
  @spec enter(module(), list(atom()), map()) :: :ok
  def enter(module, path, data) do
    defined = Module.get_attribute(module, :__defined__)
    Module.put_attribute(module, :__defined__, Map.delete(defined, path))
    write(module, path, data)
    Module.put_attribute(module, :__path__, path)
    :ok
  end

  @spec read(module(), list(atom())) :: term()
  def read(module, []), do: Module.get_attribute(module, :__config__)

  def read(module, path) do
    module
    |> Module.get_attribute(:__cache__)
    |> Map.fetch!(path)
  end

  # ---------- Private

  defp write(module, [], data) do
    Module.put_attribute(module, :__config__, data)
    :ok
  end

  defp write(module, path, data) do
    cache = Module.get_attribute(module, :__cache__)
    Module.put_attribute(module, :__cache__, Map.put(cache, path, data))
    :ok
  end

  defp place!(module, name, paths) do
    path = Module.get_attribute(module, :__path__)

    if path not in paths do
      raise "cannot use '#{name}' here"
    end

    path
  end

  defp declare_once!(module, path, name) do
    defined = Module.get_attribute(module, :__defined__)
    names = Map.get(defined, path, [])

    if name in names do
      raise "cannot declare '#{name}' multiple times"
    end

    Module.put_attribute(module, :__defined__, Map.put(defined, path, [name | names]))
  end

  # The key `at` of a row holds the changes for one path.
  #
  defp spec_at(row, path) do
    changes = row |> Map.get(:at, %{}) |> Map.get(path, %{})
    Map.merge(row, changes)
  end

  defp initial(module) when is_atom(module), do: struct(module)
  defp initial(%{} = data), do: data

  defp finish(nil, data), do: data
  defp finish({module, function, args}, data), do: apply(module, function, [data | args])

  defp attach(parent, child, %{merge: {module, function, args}}) do
    apply(module, function, [parent, child | args])
  end

  defp attach(parent, child, %{mode: :repeat, field: field}) do
    Map.put(parent, field, (Map.fetch!(parent, field) || []) ++ [child])
  end

  defp attach(parent, child, %{field: field}), do: Map.put(parent, field, child)
end
