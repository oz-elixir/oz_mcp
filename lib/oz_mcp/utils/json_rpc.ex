#
# The builders of the JSON-RPC 2.0 messages of the server and `kind/1`,
# the check of the kind of a decoded message. A request has a method and
# an id that is a string or an integer. A notification has a method and
# no id. A response has no method and a result or an error. All the
# other messages are invalid.
#
# The functions are pure. They run in the process of the caller: the
# request process (OzMcp.Handler, OzMcp.Validate.JsonRpc) and the
# senders of the messages of the server (`OzMcp.Notify`, `OzMcp.Outbound`,
# OzMcp.Task, `OzMcp.Transport.Stdio`).
#
defmodule OzMcp.Utils.JsonRpc do
  @moduledoc false

  @type kind :: :request | :notification | :response | :invalid

  @type id :: String.t() | integer() | nil

  # The kind of a decoded JSON-RPC message. A request has a method and an
  # id that is a string or an integer. A notification has a method and no
  # id. A response has no method and a result or an error. All the other
  # messages are invalid.
  #
  @spec kind(term()) :: kind()
  def kind(%{"method" => _} = rpc) do
    case Map.fetch(rpc, "id") do
      :error -> :notification
      {:ok, id} when is_binary(id) or is_integer(id) -> :request
      {:ok, _other} -> :invalid
    end
  end

  def kind(rpc) when is_map(rpc) do
    if Map.has_key?(rpc, "result") or Map.has_key?(rpc, "error"),
      do: :response,
      else: :invalid
  end

  def kind(_rpc), do: :invalid

  @spec success(id(), term()) :: map()
  def success(id, result) do
    %{"jsonrpc" => "2.0", "result" => result}
    |> maybe_id(id)
  end

  @spec error(id(), integer(), String.t(), term()) :: map()
  def error(id, code, message, data \\ nil) do
    do_error(id, code, message, data)
  end

  defp do_error(id, code, message, data) do
    %{
      "jsonrpc" => "2.0",
      "error" => %{
        "code" => code,
        "message" => message
      }
    }
    |> maybe_id(id)
    |> maybe_data(data)
  end

  defp maybe_id(struct, id) when is_binary(id) or is_integer(id), do: Map.put(struct, "id", id)
  defp maybe_id(struct, _id), do: struct

  defp maybe_data(struct, nil), do: struct
  defp maybe_data(struct, data), do: put_in(struct, ["error", "data"], data)

  @spec request(String.t() | integer(), String.t(), map() | nil) :: map()
  def request(id, method, params \\ nil) when is_binary(id) or is_integer(id) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method}
    |> maybe_params(params)
  end

  @spec notification(String.t(), map() | nil) :: map()
  def notification(method, params \\ nil) do
    %{"jsonrpc" => "2.0", "method" => method}
    |> maybe_params(params)
  end

  defp maybe_params(struct, nil), do: struct
  defp maybe_params(struct, params), do: Map.put(struct, "params", params)
end
