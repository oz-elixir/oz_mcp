#
# Tests for the shared entity block of the DSLs: the root block, the
# warnings and the shared `__before_compile__`.
# See: lib/oz_mcp/config/dsl/entity.ex
#
defmodule OzMcp.Config.DSL.EntityTest.FixtureDSL do
  require OzMcp.Config.DSL.Generate

  @entity %{
    name: :widget,
    struct: OzMcp.Structs.Prompt,
    key: :name,
    label: "widget name",
    use: "OzMcp.Config.DSL.EntityTest.FixtureDSL"
  }

  @properties %{
    title: %{paths: [[:widget]], field: :title, type: :non_empty_string},
    description: %{paths: [[:widget]], field: :description, type: :non_empty_string},
    required_scopes: %{
      paths: [[:widget]],
      field: :required_scopes,
      type: {:raises, &OzMcp.Auth.Scopes.check!/1}
    }
  }

  @blocks %{}
  @pairs %{}

  OzMcp.Config.DSL.Generate.macros()
end

defmodule OzMcp.Config.DSL.EntityTest.HookDSL do
  require OzMcp.Config.DSL.Generate

  @entity %{
    name: :widget,
    struct: OzMcp.Structs.Prompt,
    key: :name,
    label: "widget name",
    use: "OzMcp.Config.DSL.EntityTest.HookDSL",
    check_name: {__MODULE__, :__check_name__, []},
    finish: {__MODULE__, :__finish__, []},
    accepted: {__MODULE__, :__accepted__, []}
  }

  @properties %{
    title: %{paths: [[:widget]], field: :title, type: :non_empty_string},
    description: %{paths: [[:widget]], field: :description, type: :non_empty_string}
  }

  @blocks %{}
  @pairs %{}

  OzMcp.Config.DSL.Generate.macros()

  @doc false
  def __check_name__(_module, name, _stacktrace) do
    if name == "badname", do: raise(ArgumentError, "bad widget name")
    :ok
  end

  @doc false
  def __finish__(data, module) do
    if data.name == "badfinish", do: raise("bad widget finish")

    compiled = Module.get_attribute(module, :__compiled__)
    Module.put_attribute(module, :__compiled__, compiled ++ [{:matcher, data.name}])
    data
  end

  @doc false
  def __accepted__(data, _module) do
    if data.name == "badshape", do: raise("bad widget shape")
    :ok
  end
end

defmodule OzMcp.Config.DSL.EntityTest do
  use ExUnit.Case, async: true

  alias OzMcp.Config.DSL.EntityTest.{FixtureDSL, HookDSL}

  defp compile_dsl(dsl, body, opts) do
    module = "EntityFixture#{System.unique_integer([:positive, :monotonic])}"

    source = """
    defmodule #{module} do
      use #{inspect(dsl)}#{opts}

    #{body}
    end
    """

    [{compiled, _binary}] = Code.compile_string(source, "entity_fixture.ex")
    compiled
  end

  defp compile(body, opts \\ ""), do: compile_dsl(FixtureDSL, body, opts)

  describe "the root block" do
    test "adds an entity to the module" do
      module =
        compile("""
        widget "one" do
          title "One"
          description "The first widget"
        end
        """)

      assert [%OzMcp.Structs.Prompt{name: "one", title: "One"}] = module.list()
    end

    test "a DSL module exports list/0 and no list/1 or count/0" do
      module =
        compile(
          """
          widget "one" do
          end
          """,
          ", warn?: false"
        )

      assert function_exported?(module, :list, 0)
      refute function_exported?(module, :list, 1)
      refute function_exported?(module, :count, 0)
    end

    test "refuses a name that is not a string" do
      assert_raise ArgumentError, "name must be a string, got: 1", fn ->
        compile("""
        widget 1 do
        end
        """)
      end
    end

    test "refuses an empty name" do
      assert_raise ArgumentError, "'name' cannot be an empty string", fn ->
        compile("""
        widget "" do
        end
        """)
      end
    end

    test "refuses an entity inside another entity" do
      assert_raise RuntimeError, "cannot use 'widget' here", fn ->
        compile("""
        widget "outer" do
          widget "inner" do
          end
        end
        """)
      end
    end

    test "refuses a key that is declared two times" do
      assert_raise ArgumentError,
                   "duplicate widget name: \"same\" is declared two times",
                   fn ->
                     compile(
                       """
                       widget "same" do
                       end

                       widget "same" do
                       end
                       """,
                       ", warn?: false"
                     )
                   end
    end
  end

  describe "the warnings" do
    test "name the line of the user module" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          compile("""
          widget "w" do
            title "W"
          end
          """)
        end)

      assert output =~ "entity_fixture.ex:4"
      refute output =~ "dsl/entity.ex"
    end

    test "give the text of the entity that is not configured" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          compile("""
          widget "w" do
          end
          """)
        end)

      assert output =~ "The widget w does not have a title configuration"
      assert output =~ "The widget w does not have a description configuration"
    end

    test "do nothing with warn?: false" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          compile(
            """
            widget "w" do
            end
            """,
            ", warn?: false"
          )
        end)

      refute output =~ "does not have"
    end
  end

  describe "the hooks of the entity" do
    test "check the name before the block" do
      assert_raise ArgumentError, "bad widget name", fn ->
        compile_dsl(
          HookDSL,
          """
          widget "badname" do
          end
          """,
          ", warn?: false"
        )
      end
    end

    test "finish the data after the block" do
      assert_raise RuntimeError, "bad widget finish", fn ->
        compile_dsl(
          HookDSL,
          """
          widget "badfinish" do
          end
          """,
          ", warn?: false"
        )
      end
    end

    test "accept the data after the check of the key" do
      assert_raise RuntimeError, "bad widget shape", fn ->
        compile_dsl(
          HookDSL,
          """
          widget "badshape" do
          end
          """,
          ", warn?: false"
        )
      end
    end
  end

  describe "__before_compile__/2" do
    test "refuses a function that the DSL defines" do
      assert_raise RuntimeError,
                   "when using the widget DSL you can't declare list/0 function",
                   fn -> compile("def list, do: []") end
    end

    test "refuses a module with no entity" do
      assert_raise RuntimeError, "you must at least define one widget", fn -> compile("") end
    end

    test "builds the catalog, the count and the scopes" do
      module =
        compile(
          """
          widget "b" do
            required_scopes ["b", "a"]
          end

          widget "a" do
            required_scopes ["a"]
          end
          """,
          ", warn?: false"
        )

      refute function_exported?(module, :__required_scopes__, 0)
      assert Enum.map(module.__catalog__(), & &1.key) == ["b", "a"]
      assert Enum.all?(module.__catalog__(), &is_nil(&1.matcher))
    end

    test "builds a catalog with the compiled value of each entity" do
      module =
        compile_dsl(
          HookDSL,
          """
          widget "w" do
          end
          """,
          ", warn?: false"
        )

      assert [%{key: "w", matcher: {:matcher, "w"}}] = module.__catalog__()
    end
  end
end
