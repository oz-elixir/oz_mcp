#
# Tests for the macro generator that writes the macros of a DSL module
# from its tables.
# See: lib/oz_mcp/config/dsl/generate.ex
#
defmodule OzMcp.Config.DSL.GenerateTest.FixtureDSL do
  require OzMcp.Config.DSL.Generate

  @properties %{
    title: %{paths: [[:widget]], field: :title, type: :non_empty_string},
    label: %{paths: [[:widget]], field: :label, type: :string}
  }

  @blocks %{
    widget: %{
      paths: [[]],
      field: :widget,
      initial: %{title: nil, label: nil, _meta: nil}
    }
  }

  @pairs %{
    meta: %{
      paths: [[:widget]],
      field: :_meta,
      key: &__MODULE__.pair_key!/2
    }
  }

  @extra_qualify [extra: 2]

  OzMcp.Config.DSL.Generate.macros()

  @doc false
  def pair_key!(_path, key), do: to_string(key)

  @doc false
  def setup(module), do: OzMcp.Config.DSL.Core.init(module, %{widget: nil})
end

defmodule OzMcp.Config.DSL.GenerateTest do
  use ExUnit.Case, async: true

  alias OzMcp.Config.DSL.GenerateTest.FixtureDSL

  defp compile(body) do
    module = "GenerateFixture#{System.unique_integer([:positive, :monotonic])}"

    source = """
    defmodule #{module} do
      import OzMcp.Config.DSL.GenerateTest.FixtureDSL, only: [widget: 1]
      alias OzMcp.Config.DSL.GenerateTest.FixtureDSL

      FixtureDSL.setup(__MODULE__)

      #{body}

      @result Module.get_attribute(__MODULE__, :__config__)
      def __result__, do: @result
    end
    """

    [{compiled, _binary}] = Code.compile_string(source)
    compiled
  end

  describe "the tables" do
    test "give the names and the arities of the qualified calls" do
      assert Enum.sort(FixtureDSL.__qualify__()) ==
               Enum.sort(
                 label: 1,
                 title: 1,
                 widget: 1,
                 meta: 2,
                 extra: 2
               )
    end

    test "give the rows of the generated helpers" do
      assert FixtureDSL.__property__(:title) == %{
               paths: [[:widget]],
               field: :title,
               type: :non_empty_string
             }

      assert FixtureDSL.__block_spec__(:widget).field == :widget
      assert FixtureDSL.__pair__(:meta).field == :_meta
    end
  end

  describe "the generated macros" do
    test "hold one macro for each name of the tables" do
      macros = FixtureDSL.__info__(:macros)

      assert {:title, 1} in macros
      assert {:label, 1} in macros
      assert {:widget, 1} in macros
      assert {:meta, 2} in macros
      refute {:extra, 2} in macros
    end

    test "expand a property, a block and a pair" do
      module =
        compile("""
        widget do
          title "Add"
          meta :a, :b
        end
        """)

      assert module.__result__() == %{
               widget: %{title: "Add", label: nil, _meta: %{"a" => "b"}}
             }
    end

    test "keep a nested macro out of the root" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert_raise CompileError, fn ->
            compile("""
            title "Add"
            """)
          end
        end)

      assert output =~ "undefined function title/1"
    end
  end
end
