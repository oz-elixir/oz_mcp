defmodule OzMcp.Structs.ResourceLinkTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.{Annotations, Icon, ResourceLink}

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      rl = %ResourceLink{}

      assert rl.uri == ""
      assert rl.name == ""
      assert rl.title == nil
      assert rl.description == nil
      assert rl.mimeType == nil
      assert rl.icons == nil
      assert rl.annotations == nil
      assert rl.size == nil
      assert rl._meta == nil
    end
  end

  describe "uri/2" do
    test "sets uri field" do
      rl = ResourceLink.uri(%ResourceLink{}, "file:///doc.md")

      assert rl.uri == "file:///doc.md"
    end
  end

  describe "name/2" do
    test "sets name field" do
      rl = ResourceLink.name(%ResourceLink{}, "doc")

      assert rl.name == "doc"
    end
  end

  describe "title/2" do
    test "sets title field" do
      rl = ResourceLink.title(%ResourceLink{}, "My Doc")

      assert rl.title == "My Doc"
    end
  end

  describe "description/2" do
    test "sets description field" do
      rl = ResourceLink.description(%ResourceLink{}, "A resource")

      assert rl.description == "A resource"
    end
  end

  describe "mime_type/2" do
    test "sets mimeType field" do
      rl = ResourceLink.mime_type(%ResourceLink{}, "text/plain")

      assert rl.mimeType == "text/plain"
    end
  end

  describe "icons/2" do
    test "sets icons field" do
      icons = [%Icon{src: "https://example.com/icon.png"}]
      rl = ResourceLink.icons(%ResourceLink{}, icons)

      assert rl.icons == icons
    end
  end

  describe "annotations/2" do
    test "sets annotations field" do
      annotations = %Annotations{audience: [:user]}
      rl = ResourceLink.annotations(%ResourceLink{}, annotations)

      assert rl.annotations == annotations
    end
  end

  describe "size/2" do
    test "sets size field" do
      rl = ResourceLink.size(%ResourceLink{}, 1024)

      assert rl.size == 1024
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      rl = ResourceLink._meta(%ResourceLink{}, %{"key" => "value"})

      assert rl._meta == %{"key" => "value"}
    end
  end

  describe "build/1" do
    test "builds with uri and name only" do
      rl = %ResourceLink{uri: "file:///doc.md", name: "doc"}
      result = ResourceLink.build(rl)

      assert result == %{type: "resource_link", uri: "file:///doc.md", name: "doc"}
    end

    test "raises when uri is empty" do
      rl = %ResourceLink{uri: "", name: "doc"}

      assert_raise ArgumentError, "The 'uri' field cannot be an empty string", fn ->
        ResourceLink.build(rl)
      end
    end

    test "accepts a uri with no scheme" do
      rl = %ResourceLink{uri: "doc.md", name: "doc"}

      assert ResourceLink.build(rl) == %{type: "resource_link", uri: "doc.md", name: "doc"}
    end

    test "raises when name is empty" do
      rl = %ResourceLink{uri: "file:///doc.md", name: ""}

      assert_raise ArgumentError, "The 'name' field cannot be an empty string", fn ->
        ResourceLink.build(rl)
      end
    end

    test "includes title when set" do
      rl = %ResourceLink{uri: "file:///doc.md", name: "doc", title: "My Doc"}
      result = ResourceLink.build(rl)

      assert result == %{
               type: "resource_link",
               uri: "file:///doc.md",
               name: "doc",
               title: "My Doc"
             }
    end

    test "includes description when set" do
      rl = %ResourceLink{uri: "file:///doc.md", name: "doc", description: "A resource"}
      result = ResourceLink.build(rl)

      assert result == %{
               type: "resource_link",
               uri: "file:///doc.md",
               name: "doc",
               description: "A resource"
             }
    end

    test "includes mimeType when set" do
      rl = %ResourceLink{uri: "file:///doc.md", name: "doc", mimeType: "text/markdown"}
      result = ResourceLink.build(rl)

      assert result == %{
               mimeType: "text/markdown",
               name: "doc",
               type: "resource_link",
               uri: "file:///doc.md"
             }
    end

    test "does not include mimeType when nil" do
      rl = %ResourceLink{uri: "file:///doc.md", name: "doc", mimeType: nil}
      result = ResourceLink.build(rl)

      refute Map.has_key?(result, :mimeType)
    end

    test "includes icons when set" do
      rl = %ResourceLink{
        uri: "file:///doc.md",
        name: "doc",
        icons: [%Icon{src: "https://example.com/icon.png"}]
      }

      result = ResourceLink.build(rl)

      assert result == %{
               type: "resource_link",
               uri: "file:///doc.md",
               name: "doc",
               icons: [%{src: "https://example.com/icon.png"}]
             }
    end

    test "includes annotations when set" do
      rl = %ResourceLink{
        uri: "file:///doc.md",
        name: "doc",
        annotations: %Annotations{priority: 1}
      }

      result = ResourceLink.build(rl)

      assert result == %{
               type: "resource_link",
               uri: "file:///doc.md",
               name: "doc",
               annotations: %{priority: 1}
             }
    end

    test "includes size when set" do
      rl = %ResourceLink{uri: "file:///doc.md", name: "doc", size: 2048}
      result = ResourceLink.build(rl)

      assert result == %{type: "resource_link", uri: "file:///doc.md", name: "doc", size: 2048}
    end

    test "raises when size is a negative integer" do
      rl = %ResourceLink{uri: "file:///doc.md", name: "doc", size: -1}

      assert_raise ArgumentError, "The 'size' field must be a non-negative integer or nil", fn ->
        ResourceLink.build(rl)
      end
    end

    test "raises when size is a float" do
      rl = %ResourceLink{uri: "file:///doc.md", name: "doc", size: 1.5}

      assert_raise ArgumentError, "The 'size' field must be a non-negative integer or nil", fn ->
        ResourceLink.build(rl)
      end
    end

    test "raises when size is not an integer" do
      rl = %ResourceLink{uri: "file:///doc.md", name: "doc", size: "2048"}

      assert_raise ArgumentError, "The 'size' field must be a non-negative integer or nil", fn ->
        ResourceLink.build(rl)
      end
    end

    test "includes _meta when set" do
      rl = %ResourceLink{uri: "file:///doc.md", name: "doc", _meta: %{"progressToken" => 5}}
      result = ResourceLink.build(rl)

      assert result == %{
               type: "resource_link",
               uri: "file:///doc.md",
               name: "doc",
               _meta: %{"progressToken" => 5}
             }
    end

    test "does not include _meta when nil" do
      rl = %ResourceLink{uri: "file:///doc.md", name: "doc", _meta: nil}
      result = ResourceLink.build(rl)

      refute Map.has_key?(result, :_meta)
    end

    test "includes all fields when all are set" do
      rl = %ResourceLink{
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

      result = ResourceLink.build(rl)

      assert result == %{
               mimeType: "text/markdown",
               _meta: %{"key" => "val"},
               annotations: %{priority: 1},
               description: "A document",
               icons: [%{src: "https://example.com/icon.png"}],
               name: "doc",
               size: 1024,
               title: "My Doc",
               type: "resource_link",
               uri: "file:///doc.md"
             }
    end

    test "does not include nil optional fields" do
      rl = %ResourceLink{
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

      result = ResourceLink.build(rl)

      assert result == %{type: "resource_link", uri: "file:///doc.md", name: "doc"}
    end
  end
end
