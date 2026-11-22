defmodule OzMcp.Structs.BlobResourceContentsTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.BlobResourceContents

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      rbc = %BlobResourceContents{}

      assert rbc.uri == ""
      assert rbc.blob == ""
      assert rbc.mimeType == nil
      assert rbc._meta == nil
    end
  end

  describe "uri/2" do
    test "sets uri field" do
      rbc = BlobResourceContents.uri(%BlobResourceContents{}, "file:///image.png")

      assert rbc.uri == "file:///image.png"
    end
  end

  describe "blob/2" do
    test "sets blob field" do
      rbc = BlobResourceContents.blob(%BlobResourceContents{}, "base64data")

      assert rbc.blob == "base64data"
    end
  end

  describe "mime_type/2" do
    test "sets mimeType field" do
      rbc = BlobResourceContents.mime_type(%BlobResourceContents{}, "image/png")

      assert rbc.mimeType == "image/png"
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      rbc = BlobResourceContents._meta(%BlobResourceContents{}, %{"key" => "value"})

      assert rbc._meta == %{"key" => "value"}
    end
  end

  describe "build/1" do
    test "builds with uri and blob only" do
      rbc = %BlobResourceContents{uri: "file:///data.bin", blob: "base64data"}
      result = BlobResourceContents.build(rbc)

      assert result == %{uri: "file:///data.bin", blob: "base64data"}
    end

    test "raises when uri is empty" do
      rbc = %BlobResourceContents{uri: "", blob: "base64data"}

      assert_raise ArgumentError, "The 'uri' field cannot be an empty string", fn ->
        BlobResourceContents.build(rbc)
      end
    end

    test "raises when uri is not a string" do
      rbc = struct(BlobResourceContents, uri: 123, blob: "base64data")

      assert_raise ArgumentError, "The 'uri' field is required and must be a string", fn ->
        BlobResourceContents.build(rbc)
      end
    end

    test "accepts a uri with no scheme" do
      rbc = %BlobResourceContents{uri: "a", blob: "base64data"}

      assert BlobResourceContents.build(rbc) == %{uri: "a", blob: "base64data"}
    end

    test "raises when blob is empty" do
      rbc = %BlobResourceContents{uri: "file:///data.bin", blob: ""}

      assert_raise ArgumentError, "The 'blob' field cannot be an empty string", fn ->
        BlobResourceContents.build(rbc)
      end
    end

    test "raises when blob is not a string" do
      rbc = struct(BlobResourceContents, uri: "file:///data.bin", blob: 456)

      assert_raise ArgumentError, "The 'blob' field is required and must be a string", fn ->
        BlobResourceContents.build(rbc)
      end
    end

    test "raises when mimeType is an empty string" do
      rbc = %BlobResourceContents{uri: "file:///data.bin", blob: "data", mimeType: ""}

      assert_raise ArgumentError, "The 'mimeType' field cannot be an empty string", fn ->
        BlobResourceContents.build(rbc)
      end
    end

    test "raises when mimeType is not a string or nil" do
      rbc = struct(BlobResourceContents, uri: "file:///data.bin", blob: "data", mimeType: 789)

      assert_raise ArgumentError, "The 'mimeType' field must be a string or nil", fn ->
        BlobResourceContents.build(rbc)
      end
    end

    test "includes mimeType when set" do
      rbc = %BlobResourceContents{uri: "file:///img.png", blob: "data", mimeType: "image/png"}
      result = BlobResourceContents.build(rbc)

      assert result == %{mimeType: "image/png", blob: "data", uri: "file:///img.png"}
    end

    test "does not include mimeType when nil" do
      rbc = %BlobResourceContents{uri: "file:///data.bin", blob: "data", mimeType: nil}
      result = BlobResourceContents.build(rbc)

      refute Map.has_key?(result, :mimeType)
    end

    test "includes _meta when set" do
      rbc = %BlobResourceContents{
        uri: "file:///data.bin",
        blob: "data",
        _meta: %{"progressToken" => 5}
      }

      result = BlobResourceContents.build(rbc)

      assert result == %{uri: "file:///data.bin", blob: "data", _meta: %{"progressToken" => 5}}
    end

    test "does not include _meta when nil" do
      rbc = %BlobResourceContents{uri: "file:///data.bin", blob: "data", _meta: nil}
      result = BlobResourceContents.build(rbc)

      refute Map.has_key?(result, :_meta)
    end

    test "includes all optional fields" do
      rbc = %BlobResourceContents{
        uri: "file:///img.png",
        blob: "data",
        mimeType: "image/png",
        _meta: %{"key" => "val"}
      }

      result = BlobResourceContents.build(rbc)

      assert result == %{
               mimeType: "image/png",
               _meta: %{"key" => "val"},
               blob: "data",
               uri: "file:///img.png"
             }
    end

    test "does not include nil optional fields" do
      rbc = %BlobResourceContents{
        uri: "file:///data.bin",
        blob: "data",
        mimeType: nil,
        _meta: nil
      }

      result = BlobResourceContents.build(rbc)

      assert result == %{uri: "file:///data.bin", blob: "data"}
    end
  end
end
