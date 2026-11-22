defmodule OzMcp.Stream.Sse do
  @moduledoc false

  @type t :: %__MODULE__{
          id: String.t() | nil,
          event: String.t(),
          data: String.t(),
          retry: integer() | nil
        }

  defstruct id: nil, event: nil, data: nil, retry: nil

  @spec make(String.t() | nil, String.t(), binary()) :: t()
  def make(id, event, data) when is_binary(data),
    do: %__MODULE__{id: id, event: event, data: data}

  # The priming event of a stream: an event id and an empty `data` field. A
  # client that receives it knows the id it can resume from.
  #
  @spec priming(String.t()) :: String.t()
  def priming(id) when is_binary(id), do: "id: #{id}\ndata: \n\n"

  def encode(%__MODULE__{} = event) do
    current =
      ""
      |> encode_add_id(event)
      |> encode_add_event(event)
      |> encode_add_data(event)
      |> encode_add_retry(event)

    current <> "\n"
  end

  defp encode_add_id(current, event) do
    encode_add(current, event.id, "id: #{event.id}\n")
  end

  defp encode_add_event(current, event) do
    encode_add(current, event.event, "event: #{event.event}\n")
  end

  defp encode_add_data(current, event) do
    encode_add(current, event.data, "data: #{event.data}\n")
  end

  defp encode_add_retry(current, event) do
    encode_add(current, event.retry, "retry: #{event.retry}\n")
  end

  defp encode_add(current, value, _add) when is_nil(value) or value == "", do: current
  defp encode_add(current, _value, add), do: current <> add
end
