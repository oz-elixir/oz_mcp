#
# A pipeline is a list of stages. A stage reads the context and gives
# `{:cont, context}` or `{:halt, context}`.
#
# `run/2` applies the stages in order and stops at the first
# `{:halt, context}`. The halted context carries the error (and the
# headers that travel with it), so a stage does not need to check the
# error of an earlier stage: the pipeline does not call it.
#
defmodule OzMcp.Pipeline do
  @moduledoc false

  alias OzMcp.Context

  @type stage :: {module(), atom()}

  @type result :: {:cont, Context.t()} | {:halt, Context.t()}

  # Run the stages in order and stop at the first halt.
  #
  # A stage answers `{:cont, context}` or `{:halt, context}` where the
  # halted context holds an error. Any other answer is a defect of the
  # stage: `run/2` fails. The pipeline returns the answer of the last
  # stage it ran.
  #
  @spec run(Context.t(), [stage()]) :: result()
  def run(%Context{} = context, stages), do: run_stages(context, stages)

  defp run_stages(context, []), do: {:cont, context}

  defp run_stages(context, [{module, fun} | rest]) do
    case apply(module, fun, [context]) do
      {:cont, %Context{} = context} -> run_stages(context, rest)
      {:halt, %Context{error: error}} = halt when not is_nil(error) -> halt
    end
  end

  # Halt with an error code. A shortcut for the stages.
  #
  @spec halt(Context.t(), atom(), term(), list()) :: {:halt, Context.t()}
  def halt(context, code, data \\ nil, headers \\ []),
    do: {:halt, Context.put_error(context, code, data, headers)}
end
