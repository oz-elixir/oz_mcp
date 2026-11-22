#
# The rule of the spec: the `progress` value of a token MUST increase.
# A value that is not a number is not checked: it passes and `last`
# stays.
#
defmodule OzMcp.ProgressRule do
  @moduledoc false

  @max_loose 256

  @type loose :: {%{optional(term()) => number()}, :queue.queue(term())}

  @doc false
  @spec check(number() | nil, term()) :: {:ok, number() | nil} | :drop
  def check(last, value) when not is_number(value), do: {:ok, last}
  def check(nil, value), do: {:ok, value}
  def check(last, value) when value > last, do: {:ok, value}
  def check(_last, _value), do: :drop

  # The tokens that have no request entry. The queue holds the tokens in
  # the order of arrival: when the map is full, the oldest token goes.
  #
  @doc false
  @spec new_loose() :: loose()
  def new_loose, do: {%{}, :queue.new()}

  @doc false
  @spec check_loose(loose(), term(), term()) :: {:ok | :drop, loose()}
  def check_loose({values, order} = loose, token, value) do
    case Map.fetch(values, token) do
      {:ok, last} ->
        case check(last, value) do
          {:ok, last} -> {:ok, {Map.put(values, token, last), order}}
          :drop -> {:drop, loose}
        end

      :error when is_number(value) ->
        {values, order} = evict(values, order)
        {:ok, {Map.put(values, token, value), :queue.in(token, order)}}

      :error ->
        {:ok, loose}
    end
  end

  defp evict(values, order) when map_size(values) < @max_loose, do: {values, order}

  defp evict(values, order) do
    {{:value, oldest}, order} = :queue.out(order)
    {Map.delete(values, oldest), order}
  end
end
