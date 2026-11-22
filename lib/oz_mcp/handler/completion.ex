defmodule OzMcp.Handler.Completion do
  @moduledoc false

  alias OzMcp.Context
  alias OzMcp.Handler.{Invoke, Reply}
  alias OzMcp.Pipeline.Bound

  # The bind stage and the JSON-RPC stage checked the reference, the
  # argument and the module support (OzMcp.Pipeline.Bind,
  # OzMcp.Validate.JsonRpc.params/1). The callback runs in isolation: a
  # crash or a deadline overrun answers a -32603 internal error, a cancel
  # a -32800 error (see OzMcp.Handler.Invoke).
  #
  @spec complete(Context.t(), stream) :: {OzMcp.Handler.response(), stream} when stream: term()
  def complete(%{bound: %Bound{module: module}} = context, stream) do
    ctx = Context.to_ctx(context)
    ref = context.completion_ref
    argument = context.completion_argument
    completion_context = context.completion_context

    {outcome, stream} =
      Invoke.run(
        context,
        fn ->
          module.complete(ctx, ref, argument, completion_context)
        end,
        stream: stream
      )

    Reply.outcome(context, outcome, stream)
  end
end
