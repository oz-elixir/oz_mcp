defmodule OzMcp.PipelineTest do
  use ExUnit.Case, async: true

  alias OzMcp.Context
  alias OzMcp.Pipeline
  alias Support.Helpers.PipelineSteps, as: Steps

  defp context, do: %Context{}

  test "runs the stages in order and gives the context of the last stage" do
    assert {:cont, context} =
             Pipeline.run(context(), [{Steps, :first}, {Steps, :second}, {Steps, :third}])

    assert context.rpc_params[:steps] == [:first, :second, :third]
    assert is_nil(context.error)
  end

  test "an empty stage list passes the context" do
    assert {:cont, context} = Pipeline.run(context(), [])
    assert is_nil(context.error)
  end

  test "stops at the first halt and does not run the stages after it" do
    assert {:halt, context} =
             Pipeline.run(context(), [{Steps, :first}, {Steps, :refuse}, {Steps, :third}])

    assert context.rpc_params[:steps] == [:first]
    assert context.error.code == :http_invalid_session
  end

  test "a halt carries the data and the headers of the error" do
    assert {:halt, context} = Pipeline.run(context(), [{Steps, :refuse_with_data}])

    assert context.error.code == :rpc_bad_arguments
    assert context.error.data == ["bad"]
    assert context.error.headers == [{"x-a", "y"}]
  end

  test "a stage that answers another value is a defect" do
    assert_raise CaseClauseError, fn ->
      Pipeline.run(context(), [{Steps, :first}, {Steps, :bad_return}])
    end
  end

  test "a halt without an error in the context is a defect" do
    assert_raise CaseClauseError, fn ->
      Pipeline.run(context(), [{Steps, :halt_without_error}])
    end
  end

  test "run needs a context struct" do
    assert_raise FunctionClauseError, fn ->
      run_other(%{rpc_params: nil})
    end
  end

  defp run_other(value), do: Pipeline.run(value, [{Steps, :first}])

  test "halt/2 sets only the code" do
    assert {:halt, context} = Pipeline.halt(context(), :http_unavailable)

    assert context.error.code == :http_unavailable
    assert is_nil(context.error.data)
    assert context.error.headers == []
  end

  test "halt/3 and halt/4 set the data and the headers" do
    assert {:halt, context} = Pipeline.halt(context(), :rpc_bad_arguments, ["x"])
    assert context.error.data == ["x"]

    assert {:halt, context} =
             Pipeline.halt(context(), :http_insufficient_scope, nil, [{"w", "1"}])

    assert context.error.headers == [{"w", "1"}]
  end
end
