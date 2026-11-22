defmodule OzMcp.Protocol do
  @moduledoc false

  @supported ["2025-11-25"]

  @spec supported() :: [String.t()]
  def supported, do: @supported

  @spec latest() :: String.t()
  def latest, do: List.last(@supported)

  @spec supported?(term()) :: boolean()
  def supported?(v) when is_binary(v), do: v in @supported
  def supported?(_), do: false

  # The methods of the client that `OzMcp.Handler` serves (revision
  # 2025-11-25). The list comes from `OzMcp.Method.Table`. A method that
  # this list does not hold is not a defect of the caller: the telemetry
  # reports it as `:unknown`, never as the text of the client.
  #
  @spec client_methods() :: [String.t()]
  def client_methods, do: OzMcp.Method.Table.names()

  # The method of a decoded message, as the telemetry metadata holds it:
  # a method that the server serves, `:unknown` for a method that it does
  # not serve (the text of the client never goes out), or `nil` when the
  # message has no method (an answer of the client, a body that is not a
  # JSON-RPC message).
  #
  @spec bound_method(term()) :: String.t() | :unknown | nil
  def bound_method(%{"method" => method}) when is_binary(method),
    do: if(match?({:ok, _}, OzMcp.Method.Table.fetch(method)), do: method, else: :unknown)

  def bound_method(%{"method" => _other}), do: :unknown
  def bound_method(_), do: nil
end
