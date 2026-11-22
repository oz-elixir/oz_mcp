defmodule OzMcp.Structs.AudioContentTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.Annotations
  alias OzMcp.Structs.AudioContent

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      ac = %AudioContent{}

      assert ac.data == ""
      assert ac.mimeType == ""
      assert ac.annotations == nil
      assert ac._meta == nil
    end
  end

  describe "data/2" do
    test "sets data field" do
      ac = AudioContent.data(%AudioContent{}, "base64audiodata")

      assert ac.data == "base64audiodata"
    end
  end

  describe "mime_type/2" do
    test "sets mimeType field" do
      ac = AudioContent.mime_type(%AudioContent{}, "audio/wav")

      assert ac.mimeType == "audio/wav"
    end
  end

  describe "annotations/2" do
    test "sets annotations field" do
      annotations = %Annotations{audience: [:assistant]}
      ac = AudioContent.annotations(%AudioContent{}, annotations)

      assert ac.annotations == annotations
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      ac = AudioContent._meta(%AudioContent{}, %{"key" => "value"})

      assert ac._meta == %{"key" => "value"}
    end
  end

  describe "build/1" do
    test "builds with data and mimeType only" do
      ac = %AudioContent{data: "base64audiodata", mimeType: "audio/wav"}
      result = AudioContent.build(ac)

      assert result == %{type: "audio", data: "base64audiodata", mimeType: "audio/wav"}
    end

    test "raises when data is empty" do
      ac = %AudioContent{data: "", mimeType: "audio/wav"}

      assert_raise ArgumentError, "The 'data' field cannot be an empty string", fn ->
        AudioContent.build(ac)
      end
    end

    test "raises when mimeType is empty" do
      ac = %AudioContent{data: "base64audiodata", mimeType: ""}

      assert_raise ArgumentError, "The 'mimeType' field cannot be an empty string", fn ->
        AudioContent.build(ac)
      end
    end

    test "raises when data is not a string" do
      ac = %{data: 123, mimeType: "audio/wav"}

      assert_raise ArgumentError, "The 'data' field is required and must be a string", fn ->
        AudioContent.build(struct(AudioContent, ac))
      end
    end

    test "includes annotations when set" do
      ac = %AudioContent{
        data: "base64audiodata",
        mimeType: "audio/mp3",
        annotations: %Annotations{audience: [:user]}
      }

      result = AudioContent.build(ac)

      assert result == %{
               type: "audio",
               data: "base64audiodata",
               mimeType: "audio/mp3",
               annotations: %{audience: [:user]}
             }
    end

    test "includes _meta when set" do
      ac = %AudioContent{
        data: "base64audiodata",
        mimeType: "audio/wav",
        _meta: %{"progressToken" => 7}
      }

      result = AudioContent.build(ac)

      assert result == %{
               type: "audio",
               data: "base64audiodata",
               mimeType: "audio/wav",
               _meta: %{"progressToken" => 7}
             }
    end

    test "includes all optional fields" do
      ac = %AudioContent{
        data: "base64audiodata",
        mimeType: "audio/wav",
        annotations: %Annotations{priority: 1},
        _meta: %{"key" => "val"}
      }

      result = AudioContent.build(ac)

      assert result == %{
               type: "audio",
               data: "base64audiodata",
               mimeType: "audio/wav",
               annotations: %{priority: 1},
               _meta: %{"key" => "val"}
             }
    end

    test "does not include nil optional fields" do
      ac = %AudioContent{
        data: "base64audiodata",
        mimeType: "audio/wav",
        annotations: nil,
        _meta: nil
      }

      result = AudioContent.build(ac)

      assert result == %{type: "audio", data: "base64audiodata", mimeType: "audio/wav"}
    end
  end
end
