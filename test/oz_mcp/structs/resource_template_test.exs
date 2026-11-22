defmodule OzMcp.Structs.ResourceTemplateTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.Annotations
  alias OzMcp.Structs.Icon
  alias OzMcp.Structs.ResourceTemplate

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      template = %ResourceTemplate{}

      assert template.uriTemplate == ""
      assert template.name == ""
      assert template.title == nil
      assert template.description == nil
      assert template.mimeType == nil
      assert template.icons == nil
      assert template.annotations == nil
      assert template._meta == nil
      assert template.extras == nil
    end
  end

  describe "uri_template/2" do
    test "sets uriTemplate field" do
      template = ResourceTemplate.uri_template(%ResourceTemplate{}, "file:///{path}")

      assert template.uriTemplate == "file:///{path}"
    end
  end

  describe "name/2" do
    test "sets name field" do
      template = ResourceTemplate.name(%ResourceTemplate{}, "my-template")

      assert template.name == "my-template"
    end
  end

  describe "title/2" do
    test "sets title field" do
      template = ResourceTemplate.title(%ResourceTemplate{}, "My Template")

      assert template.title == "My Template"
    end
  end

  describe "description/2" do
    test "sets description field" do
      template = ResourceTemplate.description(%ResourceTemplate{}, "A test template")

      assert template.description == "A test template"
    end
  end

  describe "mime_type/2" do
    test "sets mimeType field" do
      template = ResourceTemplate.mime_type(%ResourceTemplate{}, "text/plain")

      assert template.mimeType == "text/plain"
    end
  end

  describe "icons/2" do
    test "sets icons field" do
      icons = [%Icon{src: "https://example.com/icon.png"}]
      template = ResourceTemplate.icons(%ResourceTemplate{}, icons)

      assert template.icons == icons
    end
  end

  describe "annotations/2" do
    test "sets annotations field" do
      annotations = %Annotations{audience: [:user]}
      template = ResourceTemplate.annotations(%ResourceTemplate{}, annotations)

      assert template.annotations == annotations
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      template = ResourceTemplate._meta(%ResourceTemplate{}, %{"key" => "value"})

      assert template._meta == %{"key" => "value"}
    end
  end

  describe "extras/2" do
    test "sets extras field" do
      template = ResourceTemplate.extras(%ResourceTemplate{}, %{"vendor" => 1})

      assert template.extras == %{"vendor" => 1}
    end
  end

  describe "required_scopes/2" do
    test "sets required_scopes field" do
      template = ResourceTemplate.required_scopes(%ResourceTemplate{}, ["files:write"])

      assert template.required_scopes == ["files:write"]
    end

    test "raises for a scope that is not a scope-token" do
      assert_raise ArgumentError, fn ->
        ResourceTemplate.required_scopes(%ResourceTemplate{}, ["a b"])
      end
    end
  end

  describe "build/1" do
    test "builds with uriTemplate and name only" do
      template = %ResourceTemplate{uriTemplate: "file:///{path}", name: "doc"}
      result = ResourceTemplate.build(template)

      assert result == %{uriTemplate: "file:///{path}", name: "doc"}
    end

    test "raises when uriTemplate is empty" do
      template = %ResourceTemplate{uriTemplate: "", name: "doc"}

      assert_raise ArgumentError, "The 'uriTemplate' field cannot be an empty string", fn ->
        ResourceTemplate.build(template)
      end
    end

    test "raises when uriTemplate is not a string" do
      template = struct(ResourceTemplate, uriTemplate: 123, name: "doc")

      assert_raise ArgumentError,
                   "The 'uriTemplate' field is required and must be a string",
                   fn ->
                     ResourceTemplate.build(template)
                   end
    end

    test "raises when name is empty" do
      template = %ResourceTemplate{uriTemplate: "file:///{path}", name: ""}

      assert_raise ArgumentError, "The 'name' field cannot be an empty string", fn ->
        ResourceTemplate.build(template)
      end
    end

    test "raises when name is not a string" do
      template = struct(ResourceTemplate, uriTemplate: "file:///{path}", name: 456)

      assert_raise ArgumentError, "The 'name' field is required and must be a string", fn ->
        ResourceTemplate.build(template)
      end
    end

    test "includes title when set" do
      template = %ResourceTemplate{uriTemplate: "file:///{path}", name: "doc", title: "My Doc"}
      result = ResourceTemplate.build(template)

      assert result == %{uriTemplate: "file:///{path}", name: "doc", title: "My Doc"}
    end

    test "includes description when set" do
      template = %ResourceTemplate{
        uriTemplate: "file:///{path}",
        name: "doc",
        description: "A document"
      }

      result = ResourceTemplate.build(template)

      assert result == %{uriTemplate: "file:///{path}", name: "doc", description: "A document"}
    end

    test "includes mimeType when set" do
      template = %ResourceTemplate{
        uriTemplate: "file:///{path}",
        name: "doc",
        mimeType: "text/markdown"
      }

      result = ResourceTemplate.build(template)

      assert result == %{mimeType: "text/markdown", name: "doc", uriTemplate: "file:///{path}"}
    end

    test "does not include mimeType when nil" do
      template = %ResourceTemplate{uriTemplate: "file:///{path}", name: "doc", mimeType: nil}
      result = ResourceTemplate.build(template)

      refute Map.has_key?(result, :mimeType)
    end

    test "includes icons when set" do
      icons = [%Icon{src: "https://example.com/icon.png"}]
      template = %ResourceTemplate{uriTemplate: "file:///{path}", name: "doc", icons: icons}
      result = ResourceTemplate.build(template)

      assert result == %{
               uriTemplate: "file:///{path}",
               name: "doc",
               icons: [%{src: "https://example.com/icon.png"}]
             }
    end

    test "includes icons with all icon fields built" do
      icons = [
        %Icon{src: "https://example.com/icon.png", mimeType: "image/png", theme: :dark}
      ]

      template = %ResourceTemplate{uriTemplate: "file:///{path}", name: "doc", icons: icons}
      result = ResourceTemplate.build(template)

      assert result == %{
               uriTemplate: "file:///{path}",
               name: "doc",
               icons: [
                 %{mimeType: "image/png", src: "https://example.com/icon.png", theme: :dark}
               ]
             }
    end

    test "includes annotations when set" do
      template = %ResourceTemplate{
        uriTemplate: "file:///{path}",
        name: "doc",
        annotations: %Annotations{audience: [:user], priority: 1}
      }

      result = ResourceTemplate.build(template)

      assert result == %{
               uriTemplate: "file:///{path}",
               name: "doc",
               annotations: %{audience: [:user], priority: 1}
             }
    end

    test "includes _meta when set" do
      template = %ResourceTemplate{
        uriTemplate: "file:///{path}",
        name: "doc",
        _meta: %{"progressToken" => 5}
      }

      result = ResourceTemplate.build(template)

      assert result == %{
               uriTemplate: "file:///{path}",
               name: "doc",
               _meta: %{"progressToken" => 5}
             }
    end

    test "does not include _meta when nil" do
      template = %ResourceTemplate{uriTemplate: "file:///{path}", name: "doc", _meta: nil}
      result = ResourceTemplate.build(template)

      refute Map.has_key?(result, :_meta)
    end

    test "does not include required_scopes" do
      template =
        ResourceTemplate.required_scopes(
          %ResourceTemplate{uriTemplate: "file:///{path}", name: "doc"},
          ["a"]
        )

      result = ResourceTemplate.build(template)

      refute Map.has_key?(result, :required_scopes)
    end

    test "merges extras into result" do
      template = %ResourceTemplate{
        uriTemplate: "file:///{path}",
        name: "doc",
        extras: %{"vendor" => 1}
      }

      result = ResourceTemplate.build(template)

      assert result["vendor"] == 1
    end

    test "does not include extras when nil" do
      template = %ResourceTemplate{
        uriTemplate: "file:///{path}",
        name: "doc",
        extras: nil
      }

      result = ResourceTemplate.build(template)

      refute Map.has_key?(result, "vendor")
    end

    test "extras do not override existing result keys" do
      template = %ResourceTemplate{
        uriTemplate: "file:///{path}",
        name: "doc",
        extras: %{name: "should not override"}
      }

      result = ResourceTemplate.build(template)

      assert result[:name] == "doc"
    end

    test "includes all fields when all are set" do
      template = %ResourceTemplate{
        uriTemplate: "file:///{path}",
        name: "doc",
        title: "My Doc",
        description: "A document",
        mimeType: "text/markdown",
        icons: [%Icon{src: "https://example.com/icon.png"}],
        annotations: %Annotations{priority: 1},
        _meta: %{"key" => "val"}
      }

      result = ResourceTemplate.build(template)

      assert result == %{
               mimeType: "text/markdown",
               _meta: %{"key" => "val"},
               annotations: %{priority: 1},
               description: "A document",
               icons: [%{src: "https://example.com/icon.png"}],
               name: "doc",
               title: "My Doc",
               uriTemplate: "file:///{path}"
             }
    end

    test "does not include nil optional fields" do
      template = %ResourceTemplate{
        uriTemplate: "file:///{path}",
        name: "doc",
        title: nil,
        description: nil,
        mimeType: nil,
        icons: nil,
        annotations: nil,
        _meta: nil
      }

      result = ResourceTemplate.build(template)

      assert result == %{uriTemplate: "file:///{path}", name: "doc"}
    end
  end
end
