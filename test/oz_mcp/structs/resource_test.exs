defmodule OzMcp.Structs.ResourceTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.Annotations
  alias OzMcp.Structs.Icon
  alias OzMcp.Structs.Resource

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      resource = %Resource{}

      assert resource.uri == ""
      assert resource.name == ""
      assert resource.title == nil
      assert resource.description == nil
      assert resource.mimeType == nil
      assert resource.icons == nil
      assert resource.annotations == nil
      assert resource.size == nil
      assert resource._meta == nil
      assert resource.extras == nil
    end
  end

  describe "uri/2" do
    test "sets uri field" do
      resource = Resource.uri(%Resource{}, "file:///doc.md")

      assert resource.uri == "file:///doc.md"
    end
  end

  describe "name/2" do
    test "sets name field" do
      resource = Resource.name(%Resource{}, "my-resource")

      assert resource.name == "my-resource"
    end
  end

  describe "title/2" do
    test "sets title field" do
      resource = Resource.title(%Resource{}, "My Resource")

      assert resource.title == "My Resource"
    end
  end

  describe "description/2" do
    test "sets description field" do
      resource = Resource.description(%Resource{}, "A test resource")

      assert resource.description == "A test resource"
    end
  end

  describe "mime_type/2" do
    test "sets mimeType field" do
      resource = Resource.mime_type(%Resource{}, "text/plain")

      assert resource.mimeType == "text/plain"
    end
  end

  describe "icons/2" do
    test "sets icons field" do
      icons = [%Icon{src: "https://example.com/icon.png"}]
      resource = Resource.icons(%Resource{}, icons)

      assert resource.icons == icons
    end
  end

  describe "annotations/2" do
    test "sets annotations field" do
      annotations = %Annotations{audience: [:user]}
      resource = Resource.annotations(%Resource{}, annotations)

      assert resource.annotations == annotations
    end
  end

  describe "size/2" do
    test "sets size field" do
      resource = Resource.size(%Resource{}, 1024)

      assert resource.size == 1024
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      resource = Resource._meta(%Resource{}, %{"key" => "value"})

      assert resource._meta == %{"key" => "value"}
    end
  end

  describe "extras/2" do
    test "sets extras field" do
      resource = Resource.extras(%Resource{}, %{"vendor" => 1})

      assert resource.extras == %{"vendor" => 1}
    end
  end

  describe "required_scopes/2" do
    test "sets required_scopes field" do
      resource = Resource.required_scopes(%Resource{}, ["files:write"])

      assert resource.required_scopes == ["files:write"]
    end

    test "raises for a scope that is not a scope-token" do
      assert_raise ArgumentError, fn ->
        Resource.required_scopes(%Resource{}, ["a b"])
      end
    end
  end

  describe "build/1" do
    test "builds with uri and name only" do
      resource = %Resource{uri: "file:///doc.md", name: "doc"}
      result = Resource.build(resource)

      assert result == %{uri: "file:///doc.md", name: "doc"}
    end

    test "raises when uri is empty" do
      resource = %Resource{uri: "", name: "doc"}

      assert_raise ArgumentError, "The 'uri' field cannot be an empty string", fn ->
        Resource.build(resource)
      end
    end

    test "raises when uri is not a string" do
      resource = struct(Resource, uri: 123, name: "doc")

      assert_raise ArgumentError, "The 'uri' field is required and must be a string", fn ->
        Resource.build(resource)
      end
    end

    test "accepts a custom scheme: myapp://notes/1" do
      resource = %Resource{uri: "myapp://notes/1", name: "notes"}
      result = Resource.build(resource)

      assert result == %{uri: "myapp://notes/1", name: "notes"}
    end

    test "raises when uri has no scheme" do
      resource = %Resource{uri: "notes/1", name: "doc"}

      assert_raise ArgumentError,
                   ~s(The 'uri' field must be an absolute URI with a scheme, got: "notes/1"),
                   fn ->
                     Resource.build(resource)
                   end
    end

    test "raises when uri has a space" do
      resource = %Resource{uri: "http://a b", name: "doc"}

      assert_raise ArgumentError,
                   "The 'uri' field must be an absolute URI with a scheme, got: \"http://a b\"",
                   fn ->
                     Resource.build(resource)
                   end
    end

    test "raises when name is empty" do
      resource = %Resource{uri: "file:///doc.md", name: ""}

      assert_raise ArgumentError, "The 'name' field cannot be an empty string", fn ->
        Resource.build(resource)
      end
    end

    test "raises when name is not a string" do
      resource = struct(Resource, uri: "file:///doc.md", name: 456)

      assert_raise ArgumentError, "The 'name' field is required and must be a string", fn ->
        Resource.build(resource)
      end
    end

    test "includes title when set" do
      resource = %Resource{uri: "file:///doc.md", name: "doc", title: "My Doc"}
      result = Resource.build(resource)

      assert result == %{uri: "file:///doc.md", name: "doc", title: "My Doc"}
    end

    test "includes description when set" do
      resource = %Resource{uri: "file:///doc.md", name: "doc", description: "A document"}
      result = Resource.build(resource)

      assert result == %{uri: "file:///doc.md", name: "doc", description: "A document"}
    end

    test "includes mimeType when set" do
      resource = %Resource{uri: "file:///doc.md", name: "doc", mimeType: "text/markdown"}
      result = Resource.build(resource)

      assert result == %{mimeType: "text/markdown", name: "doc", uri: "file:///doc.md"}
    end

    test "does not include mimeType when nil" do
      resource = %Resource{uri: "file:///doc.md", name: "doc", mimeType: nil}
      result = Resource.build(resource)

      refute Map.has_key?(result, :mimeType)
    end

    test "includes icons when set" do
      icons = [%Icon{src: "https://example.com/icon.png"}]
      resource = %Resource{uri: "file:///doc.md", name: "doc", icons: icons}
      result = Resource.build(resource)

      assert result == %{
               uri: "file:///doc.md",
               name: "doc",
               icons: [%{src: "https://example.com/icon.png"}]
             }
    end

    test "includes icons with all icon fields built" do
      icons = [
        %Icon{src: "https://example.com/icon.png", mimeType: "image/png", theme: :dark}
      ]

      resource = %Resource{uri: "file:///doc.md", name: "doc", icons: icons}
      result = Resource.build(resource)

      assert result == %{
               uri: "file:///doc.md",
               name: "doc",
               icons: [
                 %{mimeType: "image/png", src: "https://example.com/icon.png", theme: :dark}
               ]
             }
    end

    test "includes annotations when set" do
      resource = %Resource{
        uri: "file:///doc.md",
        name: "doc",
        annotations: %Annotations{audience: [:user], priority: 1}
      }

      result = Resource.build(resource)

      assert result == %{
               uri: "file:///doc.md",
               name: "doc",
               annotations: %{audience: [:user], priority: 1}
             }
    end

    test "includes size when set" do
      resource = %Resource{uri: "file:///doc.md", name: "doc", size: 2048}
      result = Resource.build(resource)

      assert result == %{uri: "file:///doc.md", name: "doc", size: 2048}
    end

    test "raises when size is a negative integer" do
      resource = %Resource{uri: "file:///doc.md", name: "doc", size: -1}

      assert_raise ArgumentError, "The 'size' field must be a non-negative integer or nil", fn ->
        Resource.build(resource)
      end
    end

    test "raises when size is a float" do
      resource = %Resource{uri: "file:///doc.md", name: "doc", size: 1.5}

      assert_raise ArgumentError, "The 'size' field must be a non-negative integer or nil", fn ->
        Resource.build(resource)
      end
    end

    test "raises when size is not an integer" do
      resource = %Resource{uri: "file:///doc.md", name: "doc", size: "2048"}

      assert_raise ArgumentError, "The 'size' field must be a non-negative integer or nil", fn ->
        Resource.build(resource)
      end
    end

    test "includes _meta when set" do
      resource = %Resource{
        uri: "file:///doc.md",
        name: "doc",
        _meta: %{"progressToken" => 5}
      }

      result = Resource.build(resource)

      assert result == %{uri: "file:///doc.md", name: "doc", _meta: %{"progressToken" => 5}}
    end

    test "does not include _meta when nil" do
      resource = %Resource{uri: "file:///doc.md", name: "doc", _meta: nil}
      result = Resource.build(resource)

      refute Map.has_key?(result, :_meta)
    end

    test "does not include required_scopes" do
      resource =
        Resource.required_scopes(%Resource{uri: "file:///doc.md", name: "doc"}, ["a"])

      result = Resource.build(resource)

      refute Map.has_key?(result, :required_scopes)
    end

    test "merges extras into result" do
      resource = %Resource{
        uri: "file:///doc.md",
        name: "doc",
        extras: %{"vendor" => 1}
      }

      result = Resource.build(resource)

      assert result["vendor"] == 1
    end

    test "does not include extras when nil" do
      resource = %Resource{uri: "file:///doc.md", name: "doc", extras: nil}
      result = Resource.build(resource)

      refute Map.has_key?(result, "vendor")
    end

    test "extras do not override existing result keys" do
      resource = %Resource{
        uri: "file:///doc.md",
        name: "doc",
        extras: %{name: "should not override"}
      }

      result = Resource.build(resource)

      assert result[:name] == "doc"
    end

    test "includes all fields when all are set" do
      resource = %Resource{
        uri: "file:///doc.md",
        name: "doc",
        title: "My Doc",
        description: "A document",
        mimeType: "text/markdown",
        icons: [%Icon{src: "https://example.com/icon.png"}],
        annotations: %Annotations{priority: 1},
        size: 1024,
        _meta: %{"key" => "val"}
      }

      result = Resource.build(resource)

      assert result == %{
               mimeType: "text/markdown",
               _meta: %{"key" => "val"},
               annotations: %{priority: 1},
               description: "A document",
               icons: [%{src: "https://example.com/icon.png"}],
               name: "doc",
               size: 1024,
               title: "My Doc",
               uri: "file:///doc.md"
             }
    end

    test "does not include nil optional fields" do
      resource = %Resource{
        uri: "file:///doc.md",
        name: "doc",
        title: nil,
        description: nil,
        mimeType: nil,
        icons: nil,
        annotations: nil,
        size: nil,
        _meta: nil
      }

      result = Resource.build(resource)

      assert result == %{uri: "file:///doc.md", name: "doc"}
    end
  end
end
