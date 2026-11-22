defmodule OzMcp.Structs.EmbeddedResourceTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.{Annotations, BlobResourceContents, EmbeddedResource, TextResourceContents}

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      er = %EmbeddedResource{}

      assert er.resource == %TextResourceContents{}
      assert er.annotations == nil
      assert er._meta == nil
    end
  end

  describe "resource/2" do
    test "sets resource field with TextResourceContents" do
      trc = %TextResourceContents{uri: "file:///doc.md", text: "hello"}
      er = EmbeddedResource.resource(%EmbeddedResource{}, trc)

      assert er.resource == trc
    end

    test "sets resource field with BlobResourceContents" do
      brc = %BlobResourceContents{uri: "file:///img.png", blob: "base64data"}
      er = EmbeddedResource.resource(%EmbeddedResource{}, brc)

      assert er.resource == brc
    end
  end

  describe "annotations/2" do
    test "sets annotations field" do
      annotations = %Annotations{audience: [:user]}
      er = EmbeddedResource.annotations(%EmbeddedResource{}, annotations)

      assert er.annotations == annotations
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      er = EmbeddedResource._meta(%EmbeddedResource{}, %{"key" => "value"})

      assert er._meta == %{"key" => "value"}
    end
  end

  describe "build/1" do
    test "builds with TextResourceContents" do
      er = %EmbeddedResource{
        resource: %TextResourceContents{uri: "file:///doc.md", text: "hello"}
      }

      result = EmbeddedResource.build(er)

      assert result == %{
               type: "resource",
               resource: %{uri: "file:///doc.md", text: "hello"}
             }
    end

    test "builds with BlobResourceContents" do
      er = %EmbeddedResource{
        resource: %BlobResourceContents{uri: "file:///data.bin", blob: "base64data"}
      }

      result = EmbeddedResource.build(er)

      assert result == %{
               type: "resource",
               resource: %{uri: "file:///data.bin", blob: "base64data"}
             }
    end

    test "builds TextResourceContents with all fields" do
      er = %EmbeddedResource{
        resource: %TextResourceContents{
          uri: "file:///doc.md",
          text: "content",
          mimeType: "text/markdown",
          _meta: %{"size" => 100}
        }
      }

      result = EmbeddedResource.build(er)

      assert result == %{
               type: "resource",
               resource: %{
                 mimeType: "text/markdown",
                 text: "content",
                 uri: "file:///doc.md",
                 _meta: %{"size" => 100}
               }
             }
    end

    test "builds BlobResourceContents with all fields" do
      er = %EmbeddedResource{
        resource: %BlobResourceContents{
          uri: "file:///img.png",
          blob: "base64data",
          mimeType: "image/png",
          _meta: %{"size" => 2048}
        }
      }

      result = EmbeddedResource.build(er)

      assert result == %{
               type: "resource",
               resource: %{
                 mimeType: "image/png",
                 blob: "base64data",
                 uri: "file:///img.png",
                 _meta: %{"size" => 2048}
               }
             }
    end

    test "passes through raw maps in resource without transformation" do
      raw = %{"uri" => "file:///test", "text" => "raw"}
      er = %EmbeddedResource{resource: raw}
      result = EmbeddedResource.build(er)

      assert result == %{type: "resource", resource: %{"uri" => "file:///test", "text" => "raw"}}
    end

    test "raises when resource is nil" do
      er = %EmbeddedResource{resource: nil}

      assert_raise ArgumentError, "The 'resource' field is required", fn ->
        EmbeddedResource.build(er)
      end
    end

    test "raises when resource is not a supported struct or map" do
      er = %EmbeddedResource{resource: 42}

      assert_raise ArgumentError, ~r/The 'resource' field must be a %TextResourceContents/, fn ->
        EmbeddedResource.build(er)
      end
    end

    test "includes annotations when set" do
      er = %EmbeddedResource{
        resource: %TextResourceContents{uri: "file:///doc.md", text: "hello"},
        annotations: %Annotations{audience: [:user], priority: 1}
      }

      result = EmbeddedResource.build(er)

      assert result == %{
               type: "resource",
               resource: %{uri: "file:///doc.md", text: "hello"},
               annotations: %{audience: [:user], priority: 1}
             }
    end

    test "includes _meta when set" do
      er = %EmbeddedResource{
        resource: %TextResourceContents{uri: "file:///doc.md", text: "hello"},
        _meta: %{"progressToken" => 5}
      }

      result = EmbeddedResource.build(er)

      assert result == %{
               type: "resource",
               resource: %{uri: "file:///doc.md", text: "hello"},
               _meta: %{"progressToken" => 5}
             }
    end

    test "does not include _meta when nil" do
      er = %EmbeddedResource{
        resource: %TextResourceContents{uri: "file:///doc.md", text: "hello"},
        _meta: nil
      }

      result = EmbeddedResource.build(er)

      refute Map.has_key?(result, :_meta)
    end

    test "includes all optional fields" do
      er = %EmbeddedResource{
        resource: %TextResourceContents{
          uri: "file:///doc.md",
          text: "content",
          mimeType: "text/markdown"
        },
        annotations: %Annotations{priority: 1},
        _meta: %{"key" => "val"}
      }

      result = EmbeddedResource.build(er)

      assert result == %{
               type: "resource",
               resource: %{
                 mimeType: "text/markdown",
                 text: "content",
                 uri: "file:///doc.md"
               },
               annotations: %{priority: 1},
               _meta: %{"key" => "val"}
             }
    end

    test "does not include nil optional fields" do
      er = %EmbeddedResource{
        resource: %TextResourceContents{uri: "file:///doc.md", text: "hello"},
        annotations: nil,
        _meta: nil
      }

      result = EmbeddedResource.build(er)

      assert result == %{
               type: "resource",
               resource: %{uri: "file:///doc.md", text: "hello"}
             }
    end
  end
end
