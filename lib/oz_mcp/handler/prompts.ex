defmodule OzMcp.Handler.Prompts do
  @moduledoc false

  alias OzMcp.Context
  alias OzMcp.Handler.{Invoke, Reply}
  alias OzMcp.Pipeline.Bound

  # The bind stage checked the name, the prompt and the arguments
  # (OzMcp.Pipeline.Bind). The callback runs in isolation: a crash or a
  # deadline overrun answers a -32603 internal error, a cancel a -32800
  # error (see OzMcp.Handler.Invoke).
  #
  @spec get(Context.t(), stream) :: {OzMcp.Handler.response(), stream} when stream: term()
  def get(%{bound: %Bound{module: module, name: name}} = context, stream) do
    ctx = Context.to_ctx(context)
    prompt_params = context.bound.params

    {outcome, stream} =
      Invoke.run(
        context,
        fn ->
          module.get(ctx, prompt_params)
        end,
        stream: stream,
        telemetry_name: name
      )

    Reply.outcome(context, outcome, stream)
  end
end
