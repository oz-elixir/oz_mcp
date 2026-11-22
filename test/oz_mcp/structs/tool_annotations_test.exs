defmodule OzMcp.Structs.ToolAnnotationsTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.ToolAnnotations

  describe "struct defaults" do
    test "has nil defaults for all fields" do
      ta = %ToolAnnotations{}

      assert ta.title == nil
      assert ta.readOnlyHint == nil
      assert ta.destructiveHint == nil
      assert ta.idempotentHint == nil
      assert ta.openWorldHint == nil
    end
  end

  describe "title/2" do
    test "sets title field" do
      ta = ToolAnnotations.title(%ToolAnnotations{}, "Search Tool")

      assert ta.title == "Search Tool"
    end
  end

  describe "read_only_hint/2" do
    test "sets readOnlyHint to true" do
      ta = ToolAnnotations.read_only_hint(%ToolAnnotations{}, true)

      assert ta.readOnlyHint == true
    end

    test "sets readOnlyHint to false" do
      ta = ToolAnnotations.read_only_hint(%ToolAnnotations{}, false)

      assert ta.readOnlyHint == false
    end
  end

  describe "destructive_hint/2" do
    test "sets destructiveHint to true" do
      ta = ToolAnnotations.destructive_hint(%ToolAnnotations{}, true)

      assert ta.destructiveHint == true
    end

    test "sets destructive_hint to false" do
      ta = ToolAnnotations.destructive_hint(%ToolAnnotations{}, false)

      assert ta.destructiveHint == false
    end
  end

  describe "idempotent_hint/2" do
    test "sets idempotentHint to true" do
      ta = ToolAnnotations.idempotent_hint(%ToolAnnotations{}, true)

      assert ta.idempotentHint == true
    end

    test "sets idempotentHint to false" do
      ta = ToolAnnotations.idempotent_hint(%ToolAnnotations{}, false)

      assert ta.idempotentHint == false
    end
  end

  describe "open_world_hint/2" do
    test "sets openWorldHint to true" do
      ta = ToolAnnotations.open_world_hint(%ToolAnnotations{}, true)

      assert ta.openWorldHint == true
    end

    test "sets openWorldHint to false" do
      ta = ToolAnnotations.open_world_hint(%ToolAnnotations{}, false)

      assert ta.openWorldHint == false
    end
  end

  describe "build/1" do
    test "returns empty map when all fields are nil" do
      result = ToolAnnotations.build(%ToolAnnotations{})

      assert result == %{}
    end

    test "raises when title is an empty string" do
      ta = %ToolAnnotations{title: ""}

      assert_raise ArgumentError, "The 'title' field cannot be an empty string", fn ->
        ToolAnnotations.build(ta)
      end
    end

    test "raises when readOnlyHint is not a boolean or nil" do
      ta = %ToolAnnotations{readOnlyHint: "yes"}

      assert_raise ArgumentError, "The 'readOnlyHint' field must be a boolean or nil", fn ->
        ToolAnnotations.build(ta)
      end
    end

    test "raises when destructiveHint is not a boolean or nil" do
      ta = %ToolAnnotations{destructiveHint: 1}

      assert_raise ArgumentError, "The 'destructiveHint' field must be a boolean or nil", fn ->
        ToolAnnotations.build(ta)
      end
    end

    test "raises when idempotentHint is not a boolean or nil" do
      ta = %ToolAnnotations{idempotentHint: "no"}

      assert_raise ArgumentError, "The 'idempotentHint' field must be a boolean or nil", fn ->
        ToolAnnotations.build(ta)
      end
    end

    test "raises when openWorldHint is not a boolean or nil" do
      ta = %ToolAnnotations{openWorldHint: 0}

      assert_raise ArgumentError, "The 'openWorldHint' field must be a boolean or nil", fn ->
        ToolAnnotations.build(ta)
      end
    end

    test "includes title when set" do
      ta = %ToolAnnotations{title: "Search Tool"}
      result = ToolAnnotations.build(ta)

      assert result == %{title: "Search Tool"}
    end

    test "includes readOnlyHint when set" do
      ta = %ToolAnnotations{readOnlyHint: true}
      result = ToolAnnotations.build(ta)

      assert result == %{readOnlyHint: true}
    end

    test "includes destructiveHint when set" do
      ta = %ToolAnnotations{destructiveHint: false}
      result = ToolAnnotations.build(ta)

      assert result == %{destructiveHint: false}
    end

    test "includes idempotentHint when set" do
      ta = %ToolAnnotations{idempotentHint: true}
      result = ToolAnnotations.build(ta)

      assert result == %{idempotentHint: true}
    end

    test "includes openWorldHint when set" do
      ta = %ToolAnnotations{openWorldHint: false}
      result = ToolAnnotations.build(ta)

      assert result == %{openWorldHint: false}
    end

    test "includes all fields when all are set" do
      ta = %ToolAnnotations{
        title: "Search Tool",
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
      }

      result = ToolAnnotations.build(ta)

      assert result == %{
               title: "Search Tool",
               readOnlyHint: true,
               destructiveHint: false,
               idempotentHint: true,
               openWorldHint: false
             }
    end

    test "includes only non-nil fields" do
      ta = %ToolAnnotations{
        title: "Search Tool",
        readOnlyHint: nil,
        destructiveHint: nil,
        idempotentHint: true,
        openWorldHint: nil
      }

      result = ToolAnnotations.build(ta)

      assert result == %{title: "Search Tool", idempotentHint: true}
      refute Map.has_key?(result, :readOnlyHint)
      refute Map.has_key?(result, :destructiveHint)
      refute Map.has_key?(result, :openWorldHint)
    end
  end
end
