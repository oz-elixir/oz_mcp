#
# `OzMcp.Validate.Http` uses it to read the `Accept` headers of a
# request.
#
# The parser reads every `Accept` header, splits each one on commas and
# keeps the media ranges it can parse: a media type (case insensitive),
# an optional `q` parameter (default `1.0`) and other parameters, which
# are ignored. A range whose `q` is not a number in `0.0..1.0` is
# dropped. The most specific matching range (`type/subtype`, then one
# wildcard, then `*/*`) gives the `q` of a media type; `q=0` refuses it.
#
defmodule OzMcp.Transport.Http.Accept do
  @moduledoc false

  alias Plug.Conn

  @enforce_keys [:type, :subtype]
  defstruct [:type, :subtype, q: 1.0]

  @type t :: %__MODULE__{type: String.t(), subtype: String.t(), q: float()}

  # An unparsable range is dropped: an empty list means nothing in the
  # headers is a media range.
  #
  @spec ranges(Conn.t()) :: [t()]
  def ranges(conn) do
    conn
    |> Conn.get_req_header("accept")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.flat_map(&parse_range/1)
  end

  # The most specific matching range decides: its highest q is above zero.
  #
  @spec accepts?([t()], String.t()) :: boolean()
  def accepts?(ranges, media_type) do
    [type, subtype] = String.split(media_type, "/")

    ranges
    |> Enum.filter(&(&1.type in [type, "*"] and &1.subtype in [subtype, "*"]))
    |> Enum.max_by(&{specificity(&1), &1.q}, fn -> nil end)
    |> case do
      nil -> false
      range -> range.q > 0
    end
  end

  defp specificity(range),
    do: Enum.count([range.type, range.subtype], &(&1 != "*"))

  defp parse_range(text) do
    [media | params] = text |> String.split(";") |> Enum.map(&String.trim/1)

    with [type, subtype] <- media |> String.downcase() |> String.split("/"),
         true <- type != "" and subtype != "",
         {:ok, q} <- quality(params) do
      [%__MODULE__{type: type, subtype: subtype, q: q}]
    else
      _ -> []
    end
  end

  defp quality(params) do
    case Enum.find(params, &String.match?(String.downcase(&1), ~r/^q\s*=/)) do
      nil ->
        {:ok, 1.0}

      param ->
        param
        |> String.split("=", parts: 2)
        |> List.last()
        |> String.trim()
        |> parse_q()
    end
  end

  defp parse_q(value) do
    case Float.parse(value) do
      {q, ""} when q >= 0 and q <= 1 -> {:ok, q}
      _ -> :error
    end
  end
end
