defmodule OzMcp.Structs.TaskMetadataTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.TaskMetadata

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      meta = %TaskMetadata{}

      assert meta.ttl == nil
    end
  end

  describe "ttl/2" do
    test "sets ttl field to a non-negative integer" do
      meta = TaskMetadata.ttl(%TaskMetadata{}, 5000)

      assert meta.ttl == 5000
    end

    test "sets ttl field to zero" do
      meta = TaskMetadata.ttl(%TaskMetadata{}, 0)

      assert meta.ttl == 0
    end

    test "accepts nil for ttl field" do
      meta = TaskMetadata.ttl(%TaskMetadata{ttl: 5000}, nil)

      assert meta.ttl == nil
    end
  end

  describe "build/1" do
    test "builds to an empty map when ttl is nil" do
      result = TaskMetadata.build(%TaskMetadata{})

      assert result == %{}
    end

    test "includes ttl when set" do
      result = TaskMetadata.build(%TaskMetadata{ttl: 30000})

      assert result == %{ttl: 30000}
    end

    test "includes ttl when set to zero" do
      result = TaskMetadata.build(%TaskMetadata{ttl: 0})

      assert result == %{ttl: 0}
    end

    test "raises when ttl is invalid" do
      meta = struct!(%TaskMetadata{}, ttl: -1)

      assert_raise ArgumentError, "The 'ttl' field must be a non-negative integer or nil", fn ->
        TaskMetadata.build(meta)
      end
    end
  end
end
