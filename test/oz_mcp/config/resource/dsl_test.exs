#
# Tests for the resource DSL (OzMcp.Config.Resource.DSL).
# Covers `build`/integration and `__before_compile__/1`.
# See: lib/oz_mcp/config/resource/dsl.ex
#
defmodule OzMcp.Config.Resource.DSLTest do
  use ExUnit.Case, async: true

  import Support.Factories.Resource

  describe "build" do
    # -----------------------------------------------------------------------
    # Build
    # -----------------------------------------------------------------------

    test "builds a resource with uri, title, description, mime_type and size" do
      [r] = Support.Entities.Resources.DslTest.Basic.list()

      accepted = %OzMcp.Structs.Resource{
        uri: "file:///marketing.md",
        name: "marketing.md",
        title: "Marketing rules",
        description: "All detailed marketing rules",
        mimeType: "text/markdown",
        icons: nil,
        annotations: nil,
        size: 2364,
        _meta: nil
      }

      assert r == accepted
    end

    test "builds a resource with annotations" do
      [r] = Support.Entities.Resources.DslTest.WithAnnotations.list()

      accepted = %OzMcp.Structs.Resource{
        uri: "fie:///doc.md",
        name: "doc.md",
        title: "Doc",
        description: "A doc",
        mimeType: nil,
        icons: nil,
        annotations: %OzMcp.Structs.Annotations{
          audience: ["user"],
          priority: 1,
          lastModified: "2025-01-12T15:00:58Z"
        },
        size: nil,
        _meta: nil
      }

      assert r == accepted
    end

    test "builds a resource with icons" do
      [r] = Support.Entities.Resources.DslTest.WithIcons.list()

      accepted = %OzMcp.Structs.Resource{
        uri: "file:///doc.md",
        name: "doc.md",
        title: "Doc",
        description: "A doc",
        mimeType: nil,
        icons: [
          %OzMcp.Structs.Icon{
            src: "https://assets/picto.png",
            mimeType: "image/png",
            sizes: nil,
            theme: nil
          },
          %OzMcp.Structs.Icon{
            src: "https://assets/hero.png",
            mimeType: "image/jpeg",
            sizes: ["1200x800"],
            theme: "dark"
          }
        ],
        annotations: nil,
        size: nil,
        _meta: nil
      }

      assert r == accepted
    end

    test "builds a resource with meta" do
      [r] = Support.Entities.Resources.DslTest.WithMeta.list()

      accepted = %OzMcp.Structs.Resource{
        uri: "file:///doc.md",
        name: "doc.md",
        title: "Doc",
        description: "A doc",
        mimeType: nil,
        icons: nil,
        annotations: nil,
        size: nil,
        _meta: %{"key1" => "value1", "key2" => "value2"}
      }

      assert r == accepted
    end

    test "builds multiple resources" do
      resources = Support.Entities.Resources.DslTest.Multiple.list()

      accepted = [
        %OzMcp.Structs.Resource{
          uri: "file:///first.md",
          name: "first.md",
          title: "First",
          description: "First resource",
          mimeType: nil,
          icons: nil,
          annotations: nil,
          size: nil,
          _meta: nil
        },
        %OzMcp.Structs.Resource{
          uri: "file:///second.md",
          name: "second.md",
          title: "Second",
          description: "Second resource",
          mimeType: nil,
          icons: nil,
          annotations: nil,
          size: nil,
          _meta: nil
        }
      ]

      assert resources == accepted
    end

    test "builds a resource with all features combined" do
      [r] = Support.Entities.Resources.DslTest.Full.list()

      accepted = %OzMcp.Structs.Resource{
        uri: "file:///full.md",
        name: "full.md",
        title: "Full Resource",
        description: "A resource with everything",
        mimeType: "text/markdown",
        icons: [
          %OzMcp.Structs.Icon{
            src: "https://assets/icon.svg",
            mimeType: "image/svg+xml",
            sizes: ["16x16", "32x32"],
            theme: "light"
          }
        ],
        annotations: %OzMcp.Structs.Annotations{
          audience: ["user", "assistant"],
          priority: 1,
          lastModified: "2025-06-01T00:00:00Z"
        },
        size: 4096,
        _meta: %{"version" => "1.0"}
      }

      assert r == accepted
    end
  end

  describe "__before_compile__/1" do
    # -----------------------------------------------------------------------
    # Special
    # -----------------------------------------------------------------------

    test "DSL defines list/0 and no list/1, count/0 or find/1" do
      Code.ensure_loaded(Support.Entities.Resources.DslTest.Basic)
      Code.ensure_loaded(Support.Entities.Resources.DslTest.Multiple)

      assert function_exported?(Support.Entities.Resources.DslTest.Basic, :list, 0)
      refute function_exported?(Support.Entities.Resources.DslTest.Basic, :find, 1)
      refute function_exported?(Support.Entities.Resources.DslTest.Basic, :list, 1)
      refute function_exported?(Support.Entities.Resources.DslTest.Basic, :count, 0)
      assert function_exported?(Support.Entities.Resources.DslTest.Multiple, :list, 0)
      refute function_exported?(Support.Entities.Resources.DslTest.Multiple, :find, 1)
    end

    test "list/0 returns the declared resources" do
      assert Enum.map(Support.Entities.Resources.DslTest.Basic.list(), & &1.name) == [
               "marketing.md"
             ]

      assert Enum.map(Support.Entities.Resources.DslTest.Multiple.list(), & &1.name) == [
               "first.md",
               "second.md"
             ]
    end

    test "__catalog__/0 returns one entry per resource, in the order of the declarations" do
      assert [%OzMcp.Catalog.Entry{} = entry] =
               Support.Entities.Resources.DslTest.Basic.__catalog__()

      assert entry.key == "file:///marketing.md"
      assert entry.entity == hd(Support.Entities.Resources.DslTest.Basic.list())
      assert entry.matcher == nil

      catalog = Support.Entities.Resources.DslTest.Multiple.__catalog__()
      assert Enum.map(catalog, & &1.key) == ["file:///first.md", "file:///second.md"]
      assert Enum.map(catalog, & &1.entity) == Support.Entities.Resources.DslTest.Multiple.list()
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when module defines list/0 while using resource DSL" do
      code =
        quote do
          def list, do: []
        end

      module("BeforeCompile", _code_: code) do
        resource("doc.md")
      end
      |> assert_compile_raise(
        RuntimeError,
        "when using the resource DSL you can't declare list/0 function"
      )
    end

    test "raises when no resource is defined" do
      module("BeforeCompile")
      |> assert_compile_raise(
        RuntimeError,
        "you must at least define one resource"
      )
    end
  end
end
