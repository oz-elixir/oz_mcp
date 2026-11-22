defmodule OzMcp.Testing.Sse do
  @moduledoc false

  @type event :: %{id: String.t() | nil, data: String.t()}

  @spec parse(String.t(), String.t()) :: {[event()], String.t()}
  def parse(buffer, chunk) do
    {blocks, [rest]} = Enum.split(String.split(buffer <> chunk, "\n\n"), -1)
    {Enum.flat_map(blocks, &event/1), rest}
  end

  defp event(block) do
    {id, data} =
      block
      |> String.split("\n")
      |> Enum.reduce({nil, []}, &line/2)

    case data |> Enum.reverse() |> Enum.join("\n") do
      "" -> []
      data -> [%{id: id, data: data}]
    end
  end

  defp line(":" <> _rest, acc), do: acc
  defp line("retry:" <> _rest, acc), do: acc
  defp line("id:" <> value, {_id, data}), do: {strip(value), data}
  defp line("data:" <> value, {id, data}), do: {id, [strip(value) | data]}
  defp line(_field, acc), do: acc

  defp strip(" " <> value), do: value
  defp strip(value), do: value
end
