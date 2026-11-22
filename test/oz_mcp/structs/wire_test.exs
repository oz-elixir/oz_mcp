#
# A fixture.
#
defmodule OzMcp.Structs.WireTest.Fixture do
  use OzMcp.Structs.Wire,
    const: %{type: "fixture"},
    fields: [
      id: {:string, required: true},
      mimeType: :string,
      icons: {:list_of, OzMcp.Structs.Icon},
      status: {{:one_of, [:on, :off]}, required: true, default: :on, to: :string},
      label: {{:one_of, [:a]}, to: :string},
      hidden: {:any, emit: :never},
      ttl: {:non_neg_integer, emit: :always},
      flag: {:boolean, emit: :true_only},
      _meta: :meta,
      extras: :extras
    ]
end

#
# A fixture with a rule.
#
defmodule OzMcp.Structs.WireTest.Override do
  use OzMcp.Structs.Wire, fields: [low: :number, high: :number]

  def build(struct) do
    result = super(struct)

    if struct.low > struct.high do
      raise ArgumentError, "low > high"
    end

    result
  end
end

#
# A fixture with a manual build.
#
defmodule OzMcp.Structs.WireTest.Manual do
  use OzMcp.Structs.Wire,
    build: false,
    fields: [id: {:string, required: true}, _meta: :meta]

  @spec build(t()) :: map()
  def build(%__MODULE__{id: id}) do
    %{id: id, manual: true}
  end
end

defmodule OzMcp.Structs.WireTest do
  use ExUnit.Case, async: true

  alias OzMcp.Structs.Wire.{Doc, Field, Generate}
  alias OzMcp.Structs.WireTest.{Fixture, Manual, Override}

  test "a setter has the underscored name" do
    assert Fixture.mime_type(%Fixture{}, "a/b").mimeType == "a/b"
  end

  test "build/1 sends the const, the required fields and :always" do
    assert Fixture.build(%Fixture{id: "1"}) ==
             %{type: "fixture", id: "1", status: "on", ttl: nil}
  end

  test "the first row with a fault gives the error" do
    assert_raise ArgumentError, "The 'id' field cannot be an empty string", fn ->
      Fixture.build(%Fixture{mimeType: 1})
    end
  end

  test "an extra cannot replace a field" do
    assert Fixture.build(%Fixture{id: "1", extras: %{"id" => "2", x: 1}}).id == "1"
  end

  test "an override can call super/1" do
    assert_raise ArgumentError, "low > high", fn ->
      Override.build(%Override{low: 2, high: 1})
    end
  end

  test "build: false keeps the hand-written build/1" do
    assert Manual.build(%Manual{id: "1"}) == %{id: "1", manual: true}
  end

  test "build: false still generates the setters" do
    assert Manual.id(%Manual{}, "2").id == "2"
  end

  test "a table with an unknown kind does not compile" do
    assert_raise ArgumentError, ~r/unknown kind/, fn ->
      Code.compile_string("""
      defmodule OzMcp.Structs.WireTest.Bad do
        use OzMcp.Structs.Wire, fields: [a: :nope]
      end
      """)
    end
  end

  test "a row with an unknown option does not compile" do
    assert_raise ArgumentError, ~r/unknown keys \[:requried\]/, fn ->
      Code.compile_string("""
      defmodule OzMcp.Structs.WireTest.BadRow do
        use OzMcp.Structs.Wire, fields: [a: {:string, requried: true}]
      end
      """)
    end
  end

  test "an unknown module option does not compile" do
    assert_raise ArgumentError, ~r/unknown keys \[:cosnt\]/, fn ->
      Code.compile_string("""
      defmodule OzMcp.Structs.WireTest.BadOption do
        use OzMcp.Structs.Wire, cosnt: %{type: "x"}, fields: [a: :string]
      end
      """)
    end
  end

  test "the type t/0 makes an optional field nil and a required field not nil" do
    {:ok, types} = Code.Typespec.fetch_types(OzMcp.Structs.TextContent)

    {:type, type} = Enum.find(types, &match?({:type, {:t, _, _}}, &1))
    text = type |> Code.Typespec.type_to_quoted() |> Macro.to_string()

    assert text =~ "text: String.t()"
    assert text =~ "_meta: map() | nil"
  end

  test "the moduledoc holds the field table" do
    {:docs_v1, _anno, _language, _format, %{"en" => doc}, _metadata, _docs} =
      Code.fetch_docs(Support.Helpers.WireDocFixture)

    assert doc =~ "A fixture."
    assert doc =~ "## Fields"
    assert doc =~ "| `id` | `id/2` | string | yes |"
    assert doc =~ "| `mimeType` | `mime_type/2` | string | no |"
    assert doc =~ "| `icons` | `icons/2` | list of `t:OzMcp.Structs.Icon.t/0` | no |"
    assert doc =~ "| `status` | `status/2` | `:on`, `:off` | yes |"
    assert doc =~ "| `hidden` | `hidden/2` | term, never sent | no |"
    assert doc =~ "| `_meta` | `_meta/2` | map | no |"
  end

  test "the table of a hand-written setter names the module functions" do
    {:docs_v1, _anno, _language, _format, %{"en" => doc}, _metadata, _docs} =
      Code.fetch_docs(OzMcp.Structs.ServerCapabilities)

    assert doc =~ "| `prompts` | see the module functions | map | no |"
  end

  test "the table lists the fields in order" do
    fields =
      [
        uri: {:uri, required: true},
        name: {:string, required: true},
        title: :string,
        required_scopes: :scopes
      ]
      |> Enum.map(&Field.normalize/1)

    assert Doc.table(fields) == """

           ## Fields

           | Field | Setter | Type | Required |
           |---|---|---|---|
           | `uri` | `uri/2` | absolute URI | yes |
           | `name` | `name/2` | string | yes |
           | `title` | `title/2` | string | no |
           | `required_scopes` | `required_scopes/2` | list of scopes, never sent | no |
           """
  end

  test "a uri field with the option absolute false is a string in the table" do
    fields = [uri: {:uri, required: true, absolute: false}] |> Enum.map(&Field.normalize/1)

    assert Doc.table(fields) =~ "| `uri` | `uri/2` | string | yes |"
  end

  test "the option absolute false is for a uri field only" do
    assert_raise ArgumentError, "the 'absolute' option is for a 'uri' field, got on :name", fn ->
      Field.normalize({:name, {:string, required: true, absolute: false}})
    end
  end

  test "a fixture with a moduledoc compiles with no warning" do
    name = "OzMcp.Structs.WireTest.NoWarning#{System.unique_integer([:positive])}"

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{name} do
          @moduledoc "A fixture."
          use OzMcp.Structs.Wire, fields: [id: {:string, required: true}]
        end
        """)
      end)

    assert stderr == ""
  end

  test "an optional field with to: :string is not sent when it is nil" do
    refute Map.has_key?(Fixture.build(%Fixture{id: "1"}), :label)
  end

  test "an optional field with to: :string is sent as a string" do
    assert Fixture.build(%Fixture{id: "1", label: :a}).label == "a"
  end

  @tag timeout: 10_000
  test "the code of build/1 grows in line with the rows" do
    fields = for n <- 1..24, do: Field.normalize({:"f#{n}", :string})
    puts = fields |> Generate.code([]) |> count_map_puts()

    assert puts == 48
  end

  defp count_map_puts(ast) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn
        {{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, _} = node, count -> {node, count + 1}
        node, count -> {node, count}
      end)

    count
  end
end
