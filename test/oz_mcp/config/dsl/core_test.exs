#
# Tests for the plain functions that the generated DSL macros call.
# See: lib/oz_mcp/config/dsl/core.ex
#
defmodule OzMcp.Config.DSL.CoreTest.PairKey do
  def key!(_path, key), do: "k:#{key}"
end

defmodule OzMcp.Config.DSL.CoreTest.FixtureDSL do
  @properties %{
    title: %{paths: [[:widget]], field: :title, type: :non_empty_string},
    tag: %{paths: [[:widget, :child]], field: :tag, type: :non_empty_string},
    value: %{paths: [[:entry], [:widget, :entry]], field: :value, type: :string},
    module: %{paths: [[]], field: :modules, append: :modules, type: :module}
  }

  @blocks %{
    widget: %{
      paths: [[]],
      field: :widget,
      initial: %{title: nil, children: nil, entry: nil, _meta: nil}
    },
    child: %{
      paths: [[:widget]],
      field: :children,
      initial: %{tag: nil},
      mode: :repeat,
      finish: {__MODULE__, :rich_tag, []}
    },
    entry: %{
      paths: [[], [:widget]],
      field: :entry,
      at: %{
        [] => %{initial: %{value: nil, where: :root}},
        [:widget] => %{
          initial: %{value: nil, where: :nested},
          merge: {__MODULE__, :merge_entry, []}
        }
      }
    }
  }

  @pairs %{
    meta: %{
      paths: [[:widget]],
      field: :_meta,
      key: &OzMcp.Config.DSL.CoreTest.PairKey.key!/2
    }
  }

  def __property__(name), do: Map.fetch!(@properties, name)
  def __block_spec__(name), do: Map.fetch!(@blocks, name)
  def __pair__(name), do: Map.fetch!(@pairs, name)

  def rich_tag(child), do: Map.update!(child, :tag, &"<#{&1}>")
  def merge_entry(parent, child), do: Map.put(parent, :entry, Map.put(child, :merged, true))
end

defmodule OzMcp.Config.DSL.CoreTest do
  use ExUnit.Case, async: true

  defp compile(body) do
    module = "CoreFixture#{System.unique_integer([:positive, :monotonic])}"

    source = """
    defmodule #{module} do
      alias OzMcp.Config.DSL.Core
      alias OzMcp.Config.DSL.CoreTest.FixtureDSL

      Core.init(__MODULE__, %{widget: nil, entry: nil, modules: []})

      #{body}

      @core_result Module.get_attribute(__MODULE__, :__config__)
      def __core_result__, do: @core_result
    end
    """

    [{compiled, _binary}] = Code.compile_string(source)
    compiled
  end

  describe "property" do
    test "writes the value in the open block" do
      module =
        compile("""
        Core.open_block(__MODULE__, FixtureDSL, :widget)
        Core.put_property(__MODULE__, FixtureDSL, :title, "Add")
        Core.close_block(__MODULE__, FixtureDSL, :widget)
        """)

      assert %{widget: %{title: "Add"}} = module.__core_result__()
    end

    test "checks the value before the place" do
      assert_raise ArgumentError, "'title' must be a string, got: 1", fn ->
        compile("""
        Core.put_property(__MODULE__, FixtureDSL, :title, 1)
        """)
      end
    end

    test "checks the place before a second declaration" do
      assert_raise RuntimeError, "cannot use 'title' here", fn ->
        compile("""
        Core.put_property(__MODULE__, FixtureDSL, :title, "a")
        """)
      end
    end

    test "checks the value before a second declaration" do
      assert_raise ArgumentError, "'title' must be a string, got: 1", fn ->
        compile("""
        Core.open_block(__MODULE__, FixtureDSL, :widget)
        Core.put_property(__MODULE__, FixtureDSL, :title, "a")
        Core.put_property(__MODULE__, FixtureDSL, :title, 1)
        """)
      end
    end

    test "refuses a second declaration in one block" do
      assert_raise RuntimeError, "cannot declare 'title' multiple times", fn ->
        compile("""
        Core.open_block(__MODULE__, FixtureDSL, :widget)
        Core.put_property(__MODULE__, FixtureDSL, :title, "a")
        Core.put_property(__MODULE__, FixtureDSL, :title, "b")
        """)
      end
    end

    test "appends a module to a registry" do
      module =
        compile("""
        Core.put_property(__MODULE__, FixtureDSL, :module, Foo)
        Core.put_property(__MODULE__, FixtureDSL, :module, Bar)
        """)

      assert %{modules: [Foo, Bar]} = module.__core_result__()
    end

    test "refuses a module that is already in the registry" do
      assert_raise ArgumentError, "module Foo is listed two times in 'modules'", fn ->
        compile("""
        Core.put_property(__MODULE__, FixtureDSL, :module, Foo)
        Core.put_property(__MODULE__, FixtureDSL, :module, Foo)
        """)
      end
    end
  end

  describe "repeated block" do
    test "clears the marks of the path for each block" do
      module =
        compile("""
        Core.open_block(__MODULE__, FixtureDSL, :widget)
        Core.open_block(__MODULE__, FixtureDSL, :child)
        Core.put_property(__MODULE__, FixtureDSL, :tag, "a")
        Core.close_block(__MODULE__, FixtureDSL, :child)
        Core.open_block(__MODULE__, FixtureDSL, :child)
        Core.put_property(__MODULE__, FixtureDSL, :tag, "b")
        Core.close_block(__MODULE__, FixtureDSL, :child)
        Core.close_block(__MODULE__, FixtureDSL, :widget)
        """)

      assert %{widget: %{children: [%{tag: "<a>"}, %{tag: "<b>"}]}} =
               module.__core_result__()
    end

    test "refuses a second declaration of the block" do
      assert_raise RuntimeError, "cannot declare 'widget' multiple times", fn ->
        compile("""
        Core.open_block(__MODULE__, FixtureDSL, :widget)
        Core.close_block(__MODULE__, FixtureDSL, :widget)
        Core.open_block(__MODULE__, FixtureDSL, :widget)
        """)
      end
    end
  end

  describe "block with a row for each path" do
    test "uses the initial data of the path" do
      module =
        compile("""
        Core.open_block(__MODULE__, FixtureDSL, :widget)
        Core.open_block(__MODULE__, FixtureDSL, :entry)
        Core.put_property(__MODULE__, FixtureDSL, :value, "nested")
        Core.close_block(__MODULE__, FixtureDSL, :entry)
        Core.close_block(__MODULE__, FixtureDSL, :widget)
        Core.open_block(__MODULE__, FixtureDSL, :entry)
        Core.put_property(__MODULE__, FixtureDSL, :value, "root")
        Core.close_block(__MODULE__, FixtureDSL, :entry)
        """)

      assert %{
               entry: %{value: "root", where: :root},
               widget: %{entry: %{value: "nested", where: :nested, merged: true}}
             } = module.__core_result__()
    end
  end

  describe "pair" do
    test "writes the key and the value of the open block" do
      module =
        compile("""
        Core.open_block(__MODULE__, FixtureDSL, :widget)
        Core.put_pair(__MODULE__, FixtureDSL, :meta, "a", :b)
        Core.close_block(__MODULE__, FixtureDSL, :widget)
        """)

      assert %{widget: %{_meta: %{"k:a" => "b"}}} = module.__core_result__()
    end

    test "refuses a key that is already in the block" do
      assert_raise RuntimeError, "key 'k:a' already exists", fn ->
        compile("""
        Core.open_block(__MODULE__, FixtureDSL, :widget)
        Core.put_pair(__MODULE__, FixtureDSL, :meta, "a", "b")
        Core.put_pair(__MODULE__, FixtureDSL, :meta, "a", "c")
        """)
      end
    end

    test "checks the place" do
      assert_raise RuntimeError, "cannot use 'meta' here", fn ->
        compile("""
        Core.put_pair(__MODULE__, FixtureDSL, :meta, "a", "b")
        """)
      end
    end
  end

  describe "update" do
    test "writes the data of the open block" do
      module =
        compile("""
        Core.open_block(__MODULE__, FixtureDSL, :entry)
        Core.update(__MODULE__, :value, [[:entry]], fn data -> Map.put(data, :value, "u") end)
        Core.close_block(__MODULE__, FixtureDSL, :entry)
        """)

      assert %{entry: %{value: "u", where: :root}} = module.__core_result__()
    end

    test "checks the place" do
      assert_raise RuntimeError, "cannot use 'value' here", fn ->
        compile("""
        Core.update(__MODULE__, :value, [[:entry]], fn data -> data end)
        """)
      end
    end
  end
end
