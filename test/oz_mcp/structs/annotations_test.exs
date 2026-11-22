defmodule OzMcp.Structs.AnnotationsTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.Annotations

  # -----------------------------------------------------------------------
  # Default
  # -----------------------------------------------------------------------

  describe "struct defaults" do
    test "has nil defaults for all fields" do
      annotations = %Annotations{}

      assert annotations.audience == nil
      assert annotations.priority == nil
      assert annotations.lastModified == nil
    end
  end

  # -----------------------------------------------------------------------
  # audience/2
  # -----------------------------------------------------------------------

  describe "audience/2" do
    test "sets audience field with a single value" do
      annotations = Annotations.audience(%Annotations{}, ["user"])

      assert annotations.audience == ["user"]
    end

    test ~S(sets multiple audiences as ["user", "assistant"]) do
      annotations =
        Annotations.audience(%Annotations{}, ["user", "assistant"])

      assert annotations.audience == ["user", "assistant"]
    end

    test ~S{sets multiple audiences as ["assistant", "user"] (order does not matter)} do
      annotations =
        Annotations.audience(%Annotations{}, ["assistant", "user"])

      assert annotations.audience == ["assistant", "user"]
    end
  end

  # -----------------------------------------------------------------------
  # priority/2
  # -----------------------------------------------------------------------

  describe "priority/2" do
    test "sets priority to 0" do
      annotations = Annotations.priority(%Annotations{}, 0)

      assert annotations.priority == 0
    end

    test "sets priority to 1" do
      annotations = Annotations.priority(%Annotations{}, 1)

      assert annotations.priority == 1
    end

    test "sets priority to a fractional value" do
      annotations = Annotations.priority(%Annotations{}, 0.5)

      assert annotations.priority == 0.5
    end
  end

  # -----------------------------------------------------------------------
  # last_modified/2
  # -----------------------------------------------------------------------

  describe "last_modified/2" do
    test "sets lastModified field" do
      annotations =
        Annotations.last_modified(%Annotations{}, "2025-01-12T15:00:58Z")

      assert annotations.lastModified == "2025-01-12T15:00:58Z"
    end
  end

  # -----------------------------------------------------------------------
  # build/1
  # -----------------------------------------------------------------------

  describe "build/1" do
    test "raises when all fields are nil" do
      assert_raise ArgumentError, "All fields are 'nil', remove annotations declaration", fn ->
        Annotations.build(%Annotations{})
      end
    end

    test "raises when audience is not a list" do
      annotations = %Annotations{audience: "user"}

      assert_raise ArgumentError, "'audience' must be a list, got: \"user\"", fn ->
        Annotations.build(annotations)
      end
    end

    test "raises when audience is an empty list" do
      annotations = %Annotations{audience: []}

      assert_raise ArgumentError, "'audience' cannot be an empty list", fn ->
        Annotations.build(annotations)
      end
    end

    test "raises when audience contains invalid elements" do
      annotations = %Annotations{audience: ["invalid"]}

      assert_raise ArgumentError,
                   ~r"'audience' elements must be \"user\" or \"assistant\", got: \[\"invalid\"\]",
                   fn ->
                     Annotations.build(annotations)
                   end
    end

    test "raises when audience has duplicate elements" do
      assert_raise ArgumentError,
                   ~r"'audience' has duplicates elements, got: \[\"user\", \"user\"\]",
                   fn ->
                     Annotations.build(%Annotations{audience: ["user", "user"]})
                   end

      assert_raise ArgumentError,
                   ~r"'audience' has duplicates elements, got: \[\"assistant\", \"assistant\"\]",
                   fn ->
                     Annotations.build(%Annotations{audience: ["assistant", "assistant"]})
                   end
    end

    test "accepts priority 0, 0.0, 0.5, 1 and 1.0" do
      for value <- [0, 0.0, 0.5, 1, 1.0] do
        annotations = %Annotations{priority: value}
        result = Annotations.build(annotations)

        assert result == %{priority: value}
      end
    end

    test "raises when priority is below 0" do
      assert_raise ArgumentError, "'priority' must be a number between 0 and 1, got: -0.1", fn ->
        Annotations.build(%Annotations{priority: -0.1})
      end
    end

    test "raises when priority is greater than 1" do
      assert_raise ArgumentError, "'priority' must be a number between 0 and 1, got: 1.5", fn ->
        Annotations.build(%Annotations{priority: 1.5})
      end

      assert_raise ArgumentError, "'priority' must be a number between 0 and 1, got: 2", fn ->
        Annotations.build(%Annotations{priority: 2})
      end
    end

    test "raises when priority is not a number" do
      assert_raise ArgumentError,
                   "'priority' must be a number between 0 and 1, got: \"high\"",
                   fn ->
                     Annotations.build(%Annotations{priority: "high"})
                   end
    end

    test "raises when lastModified is an empty string" do
      annotations = %Annotations{lastModified: ""}

      assert_raise ArgumentError, "The 'lastModified' field cannot be an empty string", fn ->
        Annotations.build(annotations)
      end
    end

    test "accepts 2025-01-12T15:00:58Z" do
      annotations = %Annotations{lastModified: "2025-01-12T15:00:58Z"}
      result = Annotations.build(annotations)

      assert result == %{lastModified: "2025-01-12T15:00:58Z"}
    end

    test "accepts an offset: 2025-01-12T15:00:58+02:00" do
      annotations = %Annotations{lastModified: "2025-01-12T15:00:58+02:00"}
      result = Annotations.build(annotations)

      assert result == %{lastModified: "2025-01-12T15:00:58+02:00"}
    end

    test "raises when lastModified is a date with no time" do
      annotations = %Annotations{lastModified: "2025-01-12"}

      assert_raise ArgumentError,
                   ~r/The 'lastModified' field must be an ISO 8601 date and time/,
                   fn ->
                     Annotations.build(annotations)
                   end
    end

    test "raises when lastModified is a time with no offset" do
      annotations = %Annotations{lastModified: "2025-01-12T15:00:58"}

      assert_raise ArgumentError,
                   ~r/The 'lastModified' field must be an ISO 8601 date and time/,
                   fn ->
                     Annotations.build(annotations)
                   end
    end

    test "raises when lastModified is not a date" do
      annotations = %Annotations{lastModified: "yesterday"}

      assert_raise ArgumentError,
                   ~r/The 'lastModified' field must be an ISO 8601 date and time/,
                   fn ->
                     Annotations.build(annotations)
                   end
    end

    test "raises when lastModified is not a string" do
      annotations = %Annotations{lastModified: 42}

      assert_raise ArgumentError,
                   "The 'lastModified' field must be a string or nil",
                   fn ->
                     Annotations.build(annotations)
                   end
    end

    test "includes audience when set" do
      annotations = %Annotations{audience: ["user"]}
      result = Annotations.build(annotations)

      assert result == %{audience: ["user"]}
    end

    test "includes priority when set" do
      annotations = %Annotations{priority: 1}
      result = Annotations.build(annotations)

      assert result == %{priority: 1}
    end

    test "includes lastModified when set" do
      annotations = %Annotations{lastModified: "2025-01-12T15:00:58Z"}
      result = Annotations.build(annotations)

      assert result == %{lastModified: "2025-01-12T15:00:58Z"}
    end

    test "includes all fields when all are set" do
      annotations = %Annotations{
        audience: ["user", "assistant"],
        priority: 1,
        lastModified: "2025-01-12T15:00:58Z"
      }

      result = Annotations.build(annotations)

      assert result == %{
               audience: ["user", "assistant"],
               priority: 1,
               lastModified: "2025-01-12T15:00:58Z"
             }
    end

    test "includes only non-nil fields" do
      annotations = %Annotations{
        audience: ["assistant"],
        priority: nil,
        lastModified: "2025-01-12T15:00:58Z"
      }

      result = Annotations.build(annotations)

      assert result == %{audience: ["assistant"], lastModified: "2025-01-12T15:00:58Z"}
      refute Map.has_key?(result, :priority)
    end
  end
end
