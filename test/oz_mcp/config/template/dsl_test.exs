#
# Tests for the template DSL (OzMcp.Config.Template.DSL).
# Covers `build`/integration and `__before_compile__/1`.
# See: lib/oz_mcp/config/template/dsl.ex
#
defmodule OzMcp.Config.Template.DSLTest do
  use ExUnit.Case, async: true

  import Support.Factories.Template

  describe "build" do
    # -----------------------------------------------------------------------
    # Build
    # -----------------------------------------------------------------------

    test "builds a template with uri_template, title, description, mime_type" do
      [t] = Support.Entities.Templates.DslTest.Basic.list()

      accepted = %OzMcp.Structs.ResourceTemplate{
        uriTemplate: "file://docs/{path}",
        name: "File documents",
        title: "Documents collection",
        description: "Documents collection description",
        mimeType: "text/markdown",
        icons: nil,
        annotations: nil,
        _meta: nil
      }

      assert t == accepted
    end

    test "builds a template with annotations" do
      [t] = Support.Entities.Templates.DslTest.WithAnnotations.list()

      accepted = %OzMcp.Structs.ResourceTemplate{
        uriTemplate: "file://docs/{path}",
        name: "File documents",
        title: "Documents collection",
        description: "Documents collection description",
        mimeType: nil,
        icons: nil,
        annotations: %OzMcp.Structs.Annotations{
          audience: ["user"],
          priority: 1,
          lastModified: "2025-01-12T15:00:58Z"
        },
        _meta: nil
      }

      assert t == accepted
    end

    test "builds a template with icons" do
      [t] = Support.Entities.Templates.DslTest.WithIcons.list()

      accepted = %OzMcp.Structs.ResourceTemplate{
        uriTemplate: "file://docs/{path}",
        name: "File documents",
        title: "Documents collection",
        description: "Documents collection description",
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
        _meta: nil
      }

      assert t == accepted
    end

    test "builds a template with meta" do
      [t] = Support.Entities.Templates.DslTest.WithMeta.list()

      accepted = %OzMcp.Structs.ResourceTemplate{
        uriTemplate: "file://docs/{path}",
        name: "File documents",
        title: "Documents collection",
        description: "Documents collection description",
        mimeType: nil,
        icons: nil,
        annotations: nil,
        _meta: %{"key1" => "value1", "key2" => "value2"}
      }

      assert t == accepted
    end

    test "builds multiple templates" do
      templates = Support.Entities.Templates.DslTest.Multiple.list()

      accepted = [
        %OzMcp.Structs.ResourceTemplate{
          uriTemplate: "file://docs/{path}",
          name: "File documents",
          title: "Documents collection",
          description: "Documents collection description",
          mimeType: nil,
          icons: nil,
          annotations: nil,
          _meta: nil
        },
        %OzMcp.Structs.ResourceTemplate{
          uriTemplate: "db://user/{userId}",
          name: "Database users",
          title: "User informations",
          description: "Detailed user informations",
          mimeType: nil,
          icons: nil,
          annotations: nil,
          _meta: nil
        }
      ]

      assert templates == accepted
    end

    test "builds a template with all features combined" do
      [t] = Support.Entities.Templates.DslTest.Full.list()

      accepted = %OzMcp.Structs.ResourceTemplate{
        uriTemplate: "file://docs/{path}",
        name: "File documents",
        title: "Documents collection",
        description: "Documents collection description",
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
          audience: ["assistant", "user"],
          priority: 1,
          lastModified: "2025-06-01T00:00:00Z"
        },
        _meta: %{"version" => "1.0"}
      }

      assert t == accepted
    end
  end

  describe "__before_compile__/1" do
    # -----------------------------------------------------------------------
    # Special
    # -----------------------------------------------------------------------

    test "DSL defines list/0 and no list/1, count/0 or find/1" do
      Code.ensure_loaded(Support.Entities.Templates.DslTest.Basic)
      Code.ensure_loaded(Support.Entities.Templates.DslTest.Multiple)

      assert function_exported?(Support.Entities.Templates.DslTest.Basic, :list, 0)
      refute function_exported?(Support.Entities.Templates.DslTest.Basic, :find, 1)
      refute function_exported?(Support.Entities.Templates.DslTest.Basic, :list, 1)
      refute function_exported?(Support.Entities.Templates.DslTest.Basic, :count, 0)
      assert function_exported?(Support.Entities.Templates.DslTest.Multiple, :list, 0)
      refute function_exported?(Support.Entities.Templates.DslTest.Multiple, :find, 1)
    end

    test "list/0 returns the declared templates" do
      assert Enum.map(Support.Entities.Templates.DslTest.Basic.list(), & &1.name) == [
               "File documents"
             ]

      assert Enum.map(Support.Entities.Templates.DslTest.Multiple.list(), & &1.name) == [
               "File documents",
               "Database users"
             ]
    end

    test "__catalog__/0 returns one entry per template, in the order of the declarations" do
      assert [%OzMcp.Catalog.Entry{} = entry] =
               Support.Entities.Templates.DslTest.Basic.__catalog__()

      assert entry.key == "file://docs/{path}"
      assert entry.entity == hd(Support.Entities.Templates.DslTest.Basic.list())

      catalog = Support.Entities.Templates.DslTest.Multiple.__catalog__()
      assert Enum.map(catalog, & &1.key) == ["file://docs/{path}", "db://user/{userId}"]
      assert Enum.map(catalog, & &1.entity) == Support.Entities.Templates.DslTest.Multiple.list()
    end

    test "__catalog__/0 holds the compiled matcher of each template" do
      catalog = Support.Entities.Templates.DslTest.Multiple.__catalog__()

      assert Enum.map(catalog, & &1.matcher.prefix) == ["file://docs/", "db://user/"]
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when module defines list/0 while using template DSL" do
      code =
        quote do
          def list, do: []
        end

      module("BeforeCompile", _code_: code) do
        template("doc")
      end
      |> assert_compile_raise(
        RuntimeError,
        "when using the template DSL you can't declare list/0 function"
      )
    end

    test "raises when no template is defined" do
      module("BeforeCompile") do
      end
      |> assert_compile_raise(
        RuntimeError,
        "you must at least define one template"
      )
    end
  end
end
