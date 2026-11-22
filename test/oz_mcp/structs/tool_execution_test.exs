defmodule OzMcp.Structs.ToolExecutionTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.ToolExecution

  # -----------------------------------------------------------------------
  # Default
  # -----------------------------------------------------------------------

  describe "struct defaults" do
    test "defaults taskSupport to nil" do
      te = %ToolExecution{}

      assert te.taskSupport == nil
    end

    test "defaults poll_interval to nil" do
      te = %ToolExecution{}

      assert te.poll_interval == nil
    end

    test "defaults immediate_response to nil" do
      te = %ToolExecution{}

      assert te.immediate_response == nil
    end
  end

  # -----------------------------------------------------------------------
  # task_support/2
  # -----------------------------------------------------------------------

  describe "task_support/2" do
    test "sets taskSupport to :forbidden" do
      te = ToolExecution.task_support(%ToolExecution{}, :forbidden)

      assert te.taskSupport == :forbidden
    end

    test "sets taskSupport to :optional" do
      te = ToolExecution.task_support(%ToolExecution{}, :optional)

      assert te.taskSupport == :optional
    end

    test "sets taskSupport to :required" do
      te = ToolExecution.task_support(%ToolExecution{}, :required)

      assert te.taskSupport == :required
    end

    test "sets taskSupport to 'forbidden'" do
      te = ToolExecution.task_support(%ToolExecution{}, "forbidden")

      assert te.taskSupport == "forbidden"
    end

    test "sets taskSupport to 'optional'" do
      te = ToolExecution.task_support(%ToolExecution{}, "optional")

      assert te.taskSupport == "optional"
    end

    test "sets taskSupport to 'required'" do
      te = ToolExecution.task_support(%ToolExecution{}, "required")

      assert te.taskSupport == "required"
    end

    test "overrides existing value" do
      te = ToolExecution.task_support(%ToolExecution{taskSupport: :optional}, :required)

      assert te.taskSupport == :required
    end
  end

  # -----------------------------------------------------------------------
  # poll_interval/2
  # -----------------------------------------------------------------------

  describe "poll_interval/2" do
    test "sets poll_interval to a positive integer" do
      te = ToolExecution.poll_interval(%ToolExecution{}, 5_000)

      assert te.poll_interval == 5_000
    end

    test "accepts nil (no hint)" do
      te = ToolExecution.poll_interval(%ToolExecution{poll_interval: 5_000}, nil)

      assert te.poll_interval == nil
    end

    test "overrides an existing value" do
      te = ToolExecution.poll_interval(%ToolExecution{poll_interval: 5_000}, 1_000)

      assert te.poll_interval == 1_000
    end

    test "raises when poll_interval is zero" do
      assert_raise(
        ArgumentError,
        "'poll_interval' must be a positive integer (ms) or nil, got: 0",
        fn ->
          ToolExecution.poll_interval(%ToolExecution{}, 0)
        end
      )
    end

    test "raises when poll_interval is negative" do
      assert_raise(
        ArgumentError,
        "'poll_interval' must be a positive integer (ms) or nil, got: -1",
        fn ->
          ToolExecution.poll_interval(%ToolExecution{}, -1)
        end
      )
    end

    test "raises when poll_interval is a string" do
      assert_raise(
        ArgumentError,
        "'poll_interval' must be a positive integer (ms) or nil, got: \"5\"",
        fn ->
          ToolExecution.poll_interval(%ToolExecution{}, "5")
        end
      )
    end
  end

  # -----------------------------------------------------------------------
  # immediate_response/2
  # -----------------------------------------------------------------------

  describe "immediate_response/2" do
    test "sets immediate_response to a non-empty string" do
      te = ToolExecution.immediate_response(%ToolExecution{}, "Working on it.")

      assert te.immediate_response == "Working on it."
    end

    test "accepts nil (no text)" do
      te = ToolExecution.immediate_response(%ToolExecution{immediate_response: "Old."}, nil)

      assert te.immediate_response == nil
    end

    test "overrides an existing value" do
      te =
        ToolExecution.immediate_response(
          %ToolExecution{immediate_response: "Old."},
          "New."
        )

      assert te.immediate_response == "New."
    end

    test "raises when immediate_response is an empty string" do
      assert_raise(
        ArgumentError,
        "'immediate_response' must be a non-empty string or nil, got: \"\"",
        fn ->
          ToolExecution.immediate_response(%ToolExecution{}, "")
        end
      )
    end

    test "raises when immediate_response is not a string" do
      assert_raise(
        ArgumentError,
        "'immediate_response' must be a non-empty string or nil, got: 123",
        fn ->
          ToolExecution.immediate_response(%ToolExecution{}, 123)
        end
      )
    end
  end

  # -----------------------------------------------------------------------
  # build/1
  # -----------------------------------------------------------------------

  describe "build/1" do
    test "builds with taskSupport :forbidden" do
      result = ToolExecution.build(%ToolExecution{taskSupport: :forbidden})

      assert result == %{taskSupport: :forbidden}
    end

    test "builds with taskSupport :optional" do
      result = ToolExecution.build(%ToolExecution{taskSupport: :optional})

      assert result == %{taskSupport: :optional}
    end

    test "builds with taskSupport :required" do
      result = ToolExecution.build(%ToolExecution{taskSupport: :required})

      assert result == %{taskSupport: :required}
    end

    test "builds with taskSupport 'forbidden'" do
      result = ToolExecution.build(%ToolExecution{taskSupport: "forbidden"})

      assert result == %{taskSupport: "forbidden"}
    end

    test "builds with taskSupport 'optional'" do
      result = ToolExecution.build(%ToolExecution{taskSupport: "optional"})

      assert result == %{taskSupport: "optional"}
    end

    test "builds with taskSupport 'required'" do
      result = ToolExecution.build(%ToolExecution{taskSupport: "required"})

      assert result == %{taskSupport: "required"}
    end

    test "raises when taskSupport is nil (default)" do
      assert_raise(
        ArgumentError,
        "All fields are 'nil', remove 'execution' declaration",
        fn ->
          ToolExecution.build(%ToolExecution{})
        end
      )
    end

    test "raises when taskSupport is an invalid value" do
      assert_raise(
        ArgumentError,
        "'task_support' allow only three values: 'forbidden', 'optional', 'required'",
        fn ->
          ToolExecution.build(%ToolExecution{taskSupport: "invalid"})
        end
      )
    end

    test "raises when a struct literal carries a string poll_interval" do
      assert_raise(
        ArgumentError,
        "'poll_interval' must be a positive integer (ms) or nil, got: \"5\"",
        fn ->
          ToolExecution.build(%ToolExecution{taskSupport: :optional, poll_interval: "5"})
        end
      )
    end

    test "raises when a struct literal carries a zero poll_interval" do
      assert_raise(
        ArgumentError,
        "'poll_interval' must be a positive integer (ms) or nil, got: 0",
        fn ->
          ToolExecution.build(%ToolExecution{taskSupport: :optional, poll_interval: 0})
        end
      )
    end

    test "raises when a struct literal carries a negative poll_interval" do
      assert_raise(
        ArgumentError,
        "'poll_interval' must be a positive integer (ms) or nil, got: -1",
        fn ->
          ToolExecution.build(%ToolExecution{taskSupport: :optional, poll_interval: -1})
        end
      )
    end

    test "never emits the poll interval of the tool" do
      struct =
        %ToolExecution{}
        |> ToolExecution.task_support(:optional)
        |> ToolExecution.poll_interval(5_000)

      result = ToolExecution.build(struct)

      assert result == %{taskSupport: :optional}
      refute Map.has_key?(result, :poll_interval)
      refute Map.has_key?(result, :pollInterval)
    end

    test "raises when a struct literal carries an empty immediate_response" do
      assert_raise(
        ArgumentError,
        "'immediate_response' must be a non-empty string or nil, got: \"\"",
        fn ->
          ToolExecution.build(%ToolExecution{taskSupport: :optional, immediate_response: ""})
        end
      )
    end

    test "raises when a struct literal carries a non-string immediate_response" do
      assert_raise(
        ArgumentError,
        "'immediate_response' must be a non-empty string or nil, got: 123",
        fn ->
          ToolExecution.build(%ToolExecution{taskSupport: :optional, immediate_response: 123})
        end
      )
    end

    test "never emits the immediate response of the tool" do
      struct =
        %ToolExecution{}
        |> ToolExecution.task_support(:optional)
        |> ToolExecution.immediate_response("Working on it.")

      result = ToolExecution.build(struct)

      assert result == %{taskSupport: :optional}
      refute Map.has_key?(result, :immediate_response)
      refute Map.has_key?(result, :immediateResponse)
    end
  end
end
