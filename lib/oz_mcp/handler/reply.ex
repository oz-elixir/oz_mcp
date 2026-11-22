defmodule OzMcp.Handler.Reply do
  @moduledoc false

  alias OzMcp.Utils.JsonRpc

  @type stream :: OzMcp.Stream.t() | nil

  @spec success(OzMcp.Context.t(), map(), stream()) :: {{:rpc_success, map()}, stream()}
  def success(context, result, stream),
    do: {{:rpc_success, JsonRpc.success(context.rpc_id, result)}, stream}

  @spec error(OzMcp.Context.t(), integer(), String.t(), stream()) ::
          {{:rpc_error, map()}, stream()}
  def error(context, code, message, stream), do: error(context, code, message, nil, stream)

  @spec error(OzMcp.Context.t(), integer(), String.t(), term(), stream()) ::
          {{:rpc_error, map()}, stream()}
  def error(context, code, message, data, stream),
    do: {{:rpc_error, JsonRpc.error(context.rpc_id, code, message, data)}, stream}

  @spec invalid_params(OzMcp.Context.t(), String.t(), stream()) ::
          {{:rpc_error, map()}, stream()}
  def invalid_params(context, message, stream), do: error(context, -32602, message, stream)

  # The answer for a path of a method that cannot continue: the answer is
  # always the standard internal error, so the client sees one code for
  # every internal failure of the framework.
  #
  @spec internal(OzMcp.Context.t(), stream()) :: {{:rpc_error, map()}, stream()}
  def internal(context, stream), do: error(context, -32603, "internal server error", stream)

  # The outcome of `Invoke.run/3`: the callback result or the error struct.
  #
  @spec outcome(OzMcp.Context.t(), {:ok, map()} | {:error, map()}, stream()) ::
          {{:rpc_success | :rpc_error, map()}, stream()}
  def outcome(context, {:ok, result}, stream), do: success(context, result, stream)

  def outcome(context, {:error, err}, stream),
    do: error(context, err.code, err.message, err.data, stream)
end
