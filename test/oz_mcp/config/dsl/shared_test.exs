#
# Tests for the rows that the DSL tables share.
# See: lib/oz_mcp/config/dsl/shared.ex
#
defmodule OzMcp.Config.DSL.SharedTest do
  use ExUnit.Case, async: true

  alias OzMcp.Config.DSL.{Checks, Shared, Type}
  alias OzMcp.Structs.{Annotations, Icon}

  describe "entity_properties/1" do
    test "gives the three rows at the root path" do
      rows = Shared.entity_properties(:tool)

      assert %{paths: [[:tool]], field: :title, type: :non_empty_string} = rows.title

      assert %{paths: [[:tool]], field: :description, type: :non_empty_string} =
               rows.description

      assert %{paths: [[:tool]], field: :required_scopes} = rows.required_scopes
      assert {:raises, _fun} = rows.required_scopes.type
    end
  end

  describe "icon_properties/1" do
    test "gives the four rows at the icon path" do
      rows = Shared.icon_properties([:tool])
      path = [:tool, :icon]

      assert rows.src.paths == [path]
      assert rows.src.field == :src
      assert rows.mime_type.paths == [path]
      assert rows.mime_type.field == :mimeType
      assert rows.sizes.paths == [path]
      assert rows.sizes.field == :sizes
      assert rows.theme.paths == [path]
      assert rows.theme.field == :theme
    end

    test "checks the values with the messages of the DSL" do
      rows = Shared.icon_properties([:tool])

      assert Type.check!(:src, rows.src.type, "https://a.example/i.png") ==
               "https://a.example/i.png"

      assert_raise(ArgumentError, "'src' cannot be an empty string", fn ->
        Type.check!(:src, rows.src.type, "")
      end)

      assert Type.check!(:sizes, rows.sizes.type, ["48x48", "any"]) == ["48x48", "any"]

      assert_raise(
        ArgumentError,
        ~s('sizes' entry must be "any" or a "WxH" string such as "48x48", got: "big"),
        fn -> Type.check!(:sizes, rows.sizes.type, ["big"]) end
      )

      assert Type.check!(:theme, rows.theme.type, "dark") == "dark"

      assert_raise(
        ArgumentError,
        "'theme' can take only two values: 'light' or 'dark'",
        fn -> Type.check!(:theme, rows.theme.type, "blue") end
      )
    end
  end

  describe "icon_block/1" do
    test "gives a repeated icon block of the parent" do
      assert %{
               icon: %{
                 paths: [[:tool]],
                 field: :icons,
                 initial: Icon,
                 mode: :repeat,
                 finish: {Checks, :icon!, []}
               }
             } = Shared.icon_block([:tool])
    end
  end

  describe "meta_pair/1" do
    test "gives the meta row for each path" do
      assert %{meta: %{paths: [[:tool]], field: :_meta, key: key}} =
               Shared.meta_pair([[:tool]])

      assert key.([:tool], "region") == "region"
    end
  end

  describe "resource_properties/1" do
    test "merges the entity, the icon and the annotations rows" do
      rows = Shared.resource_properties(:resource)

      assert %{paths: [[:resource]], field: :title} = rows.title
      assert %{paths: [[:resource, :icon]], field: :src} = rows.src
      assert %{paths: [[:resource], [:resource, :icon]], field: :mimeType} = rows.mime_type
      assert %{paths: [[:resource, :annotations]], field: :audience} = rows.audience
      assert %{paths: [[:resource, :annotations]], field: :priority} = rows.priority
      assert %{paths: [[:resource, :annotations]], field: :lastModified} = rows.last_modified
    end

    test "checks the annotations values with the messages of the DSL" do
      rows = Shared.resource_properties(:resource)

      assert Type.check!(:audience, rows.audience.type, ["user"]) == ["user"]

      assert_raise(ArgumentError, "'audience' cannot be an empty list", fn ->
        Type.check!(:audience, rows.audience.type, [])
      end)

      assert Type.check!(:priority, rows.priority.type, 0.5) == 0.5

      assert_raise(ArgumentError, "'priority' must be a number between 0 and 1, got: 2", fn ->
        Type.check!(:priority, rows.priority.type, 2)
      end)

      assert Type.check!(:last_modified, rows.last_modified.type, "2025-01-12T15:00:58Z") ==
               "2025-01-12T15:00:58Z"
    end
  end

  describe "resource_blocks/1" do
    test "gives the icon and the annotations blocks" do
      blocks = Shared.resource_blocks(:resource)

      assert %{icon: %{paths: [[:resource]], initial: Icon, mode: :repeat}} = blocks

      assert %{
               annotations: %{
                 paths: [[:resource]],
                 field: :annotations,
                 initial: Annotations,
                 finish:
                   {Checks, :not_empty!, [[:audience, :priority, :lastModified], "annotations"]}
               }
             } = blocks
    end
  end

  describe "list_block/2" do
    test "gives the registry row at the root" do
      block = Shared.list_block(:tools, "tool")

      assert block.paths == [[]]
      assert block.field == :tools

      assert %{
               initial: %{paginate: nil, list_result: nil, modules: []},
               finish: {Checks, :modules!, ["tool"]}
             } = block.at[[]]
    end

    test "gives a capability row for resources only" do
      resources = Shared.list_block(:resources, "resource")

      assert resources.paths == [[], [:capabilities]]

      assert %{initial: %{subscribe: nil}, merge: {_, :__merge_capability__, [:resources]}} =
               resources.at[[:capabilities]]

      for {name, entity} <- [tools: "tool", prompts: "prompt"] do
        refute Map.has_key?(Shared.list_block(name, entity).at, [:capabilities])
      end
    end
  end
end
