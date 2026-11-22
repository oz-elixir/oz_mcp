defmodule OzMcp.Structs.RelatedTaskMetadataTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.RelatedTaskMetadata

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      meta = %RelatedTaskMetadata{}

      assert meta.taskId == ""
    end
  end

  describe "task_id/2" do
    test "sets taskId field" do
      meta = RelatedTaskMetadata.task_id(%RelatedTaskMetadata{}, "task-42")

      assert meta.taskId == "task-42"
    end
  end

  describe "build/1" do
    test "builds with taskId" do
      result = RelatedTaskMetadata.build(%RelatedTaskMetadata{taskId: "task-42"})

      assert result == %{taskId: "task-42"}
    end

    test "raises when taskId is empty" do
      assert_raise ArgumentError, "The 'taskId' field cannot be an empty string", fn ->
        RelatedTaskMetadata.build(%RelatedTaskMetadata{taskId: ""})
      end
    end

    test "raises when taskId is not a string" do
      meta = struct!(%RelatedTaskMetadata{}, taskId: 123)

      assert_raise ArgumentError, "The 'taskId' field is required and must be a string", fn ->
        RelatedTaskMetadata.build(meta)
      end
    end

    test "raises when taskId is nil" do
      meta = struct!(%RelatedTaskMetadata{}, taskId: nil)

      assert_raise ArgumentError, "The 'taskId' field is required and must be a string", fn ->
        RelatedTaskMetadata.build(meta)
      end
    end
  end
end
