defmodule OzMcp.Structs.ImageContentTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.Annotations
  alias OzMcp.Structs.ImageContent

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      ic = %ImageContent{}

      assert ic.data == ""
      assert ic.mimeType == ""
      assert ic.annotations == nil
      assert ic._meta == nil
    end
  end

  describe "data/2" do
    test "sets data field" do
      ic = ImageContent.data(%ImageContent{}, "base64data")

      assert ic.data == "base64data"
    end
  end

  describe "mime_type/2" do
    test "sets mimeType field" do
      ic = ImageContent.mime_type(%ImageContent{}, "image/png")

      assert ic.mimeType == "image/png"
    end
  end

  describe "annotations/2" do
    test "sets annotations field" do
      annotations = %Annotations{audience: [:assistant]}
      ic = ImageContent.annotations(%ImageContent{}, annotations)

      assert ic.annotations == annotations
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      ic = ImageContent._meta(%ImageContent{}, %{"key" => "value"})

      assert ic._meta == %{"key" => "value"}
    end
  end

  describe "build/1" do
    test "builds with data and mimeType only" do
      ic = %ImageContent{data: "base64data", mimeType: "image/png"}
      result = ImageContent.build(ic)

      assert result == %{type: "image", data: "base64data", mimeType: "image/png"}
    end

    test "raises when data is empty" do
      ic = %ImageContent{data: "", mimeType: "image/png"}

      assert_raise ArgumentError, "The 'data' field cannot be an empty string", fn ->
        ImageContent.build(ic)
      end
    end

    test "raises when mimeType is empty" do
      ic = %ImageContent{data: "base64data", mimeType: ""}

      assert_raise ArgumentError, "The 'mimeType' field cannot be an empty string", fn ->
        ImageContent.build(ic)
      end
    end

    test "raises when data is not a string" do
      ic = %{data: 123, mimeType: "image/png"}

      assert_raise ArgumentError, "The 'data' field is required and must be a string", fn ->
        ImageContent.build(struct(ImageContent, ic))
      end
    end

    test "includes annotations when set" do
      ic = %ImageContent{
        data: "base64data",
        mimeType: "image/jpeg",
        annotations: %Annotations{audience: [:user]}
      }

      result = ImageContent.build(ic)

      assert result == %{
               type: "image",
               data: "base64data",
               mimeType: "image/jpeg",
               annotations: %{audience: [:user]}
             }
    end

    test "includes _meta when set" do
      ic = %ImageContent{
        data: "base64data",
        mimeType: "image/png",
        _meta: %{"progressToken" => 7}
      }

      result = ImageContent.build(ic)

      assert result == %{
               type: "image",
               data: "base64data",
               mimeType: "image/png",
               _meta: %{"progressToken" => 7}
             }
    end

    test "includes all optional fields" do
      ic = %ImageContent{
        data: "base64data",
        mimeType: "image/png",
        annotations: %Annotations{priority: 1},
        _meta: %{"key" => "val"}
      }

      result = ImageContent.build(ic)

      assert result == %{
               type: "image",
               data: "base64data",
               mimeType: "image/png",
               annotations: %{priority: 1},
               _meta: %{"key" => "val"}
             }
    end

    test "does not include nil optional fields" do
      ic = %ImageContent{
        data: "base64data",
        mimeType: "image/png",
        annotations: nil,
        _meta: nil
      }

      result = ImageContent.build(ic)

      assert result == %{type: "image", data: "base64data", mimeType: "image/png"}
    end
  end
end
