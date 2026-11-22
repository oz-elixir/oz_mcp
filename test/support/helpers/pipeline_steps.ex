#
# Stage functions for the tests of `OzMcp.Pipeline`. Each stage marks
# the context with the name it ran under (the `:steps` key of
# `rpc_params`), so a test can read the stages that ran and the stages
# that the pipeline stopped before.
#
defmodule Support.Helpers.PipelineSteps do
  alias OzMcp.Context
  alias OzMcp.Pipeline

  @spec first(Context.t()) :: Pipeline.result()
  def first(context), do: {:cont, mark(context, :first)}

  @spec second(Context.t()) :: Pipeline.result()
  def second(context), do: {:cont, mark(context, :second)}

  @spec third(Context.t()) :: Pipeline.result()
  def third(context), do: {:cont, mark(context, :third)}

  @spec refuse(Context.t()) :: Pipeline.result()
  def refuse(context), do: Pipeline.halt(context, :http_invalid_session)

  @spec refuse_with_data(Context.t()) :: Pipeline.result()
  def refuse_with_data(context),
    do: Pipeline.halt(context, :rpc_bad_arguments, ["bad"], [{"x-a", "y"}])

  @spec bad_return(term()) :: :ok
  def bad_return(_context), do: :ok

  @spec halt_without_error(Context.t()) :: {:halt, Context.t()}
  def halt_without_error(context), do: {:halt, context}

  @spec mark(Context.t(), atom()) :: Context.t()
  def mark(context, name) do
    params = context.rpc_params || %{}
    steps = Map.get(params, :steps, [])
    Map.put(context, :rpc_params, Map.put(params, :steps, steps ++ [name]))
  end
end
