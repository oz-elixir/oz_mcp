defmodule OzMcp.Utils.TemplateUri.Matcher do
  @moduledoc false

  # The budget counts the work of one match. A try costs one unit. A scan
  # of the URI (the search of a stop byte, the search of the positions of
  # a literal or of a prefix character, the check of the raw bytes of a
  # value, the decode of the values) costs one unit for each byte. When
  # the budget is over, the answer is no match. A uri of 16 KiB that
  # matches a template of 16 expressions stays under the default budget.
  #
  @budget 200_000

  @plain_ops [:simple, :reserved, :fragment, :label, :path]
  @named_ops [:param, :query, :cont]
  @prefix_ops [:fragment, :label, :path, :param, :query, :cont]

  @type params :: %{optional(String.t()) => String.t()}

  @doc false
  @spec default_budget() :: pos_integer()
  def default_budget, do: @budget

  @spec run(map(), binary()) :: {:ok, params()} | :nomatch
  def run(compiled, uri), do: run(compiled, uri, @budget)

  @doc false
  @spec run(map(), binary(), non_neg_integer()) :: {:ok, params()} | :nomatch
  def run(%{parts: parts}, uri, budget) when is_binary(uri) and is_integer(budget) do
    case walk(parts, uri, %{}, budget) do
      {:ok, raw_params, budget_left} ->
        case decode_params(raw_params, budget_left) do
          {:ok, params} -> {:ok, params}
          _nomatch_or_budget -> :nomatch
        end

      _nomatch_or_budget ->
        :nomatch
    end
  end

  def run(_compiled, _uri, _budget), do: :nomatch

  # Gives {result, units_used} for the tests. The walk keeps the raw
  # values; each value is decoded one time, after the walk has matched
  # the full URI.
  #
  @doc false
  @spec cost(map(), binary(), non_neg_integer()) ::
          {{:ok, params()} | :nomatch, non_neg_integer()}
  def cost(%{parts: parts}, uri, budget) when is_binary(uri) and is_integer(budget) do
    case walk(parts, uri, %{}, budget) do
      {:ok, raw_params, budget_left} ->
        case decode_params(raw_params, budget_left) do
          {:ok, params} -> {{:ok, params}, budget - budget_left}
          :nomatch -> {:nomatch, budget - budget_left}
          :budget -> {:nomatch, budget}
        end

      {:nomatch, budget_left} ->
        {:nomatch, budget - budget_left}

      :budget ->
        {:nomatch, budget}
    end
  end

  def cost(_compiled, _uri, _budget), do: {:nomatch, 0}

  # The walk holds the raw values of the parameters in the params map.
  # Each value goes through check_raw/3 at put time: the check sees the
  # raw bytes, so a bad triplet and, for the operators that do not let
  # '/' cross, the triplet %2F give no match during the walk.
  #
  defp walk([], "", params, budget), do: {:ok, params, budget}
  defp walk([], _rest, _params, budget), do: {:nomatch, budget}

  defp walk([{:lit, lit} | parts], uri, params, budget) when budget > 0 do
    size = byte_size(lit)

    case uri do
      <<^lit::binary-size(size), rest::binary>> -> walk(parts, rest, params, budget - 1)
      _other -> {:nomatch, budget}
    end
  end

  defp walk([{:lit, _lit} | _parts], _uri, _params, _budget), do: :budget

  defp walk([{:exp, _op, _specs} | _parts], _uri, _params, budget) when budget <= 0, do: :budget

  defp walk([{:exp, op, specs} | parts], uri, params, budget) when op in @plain_ops do
    {prefix, sep, stops, slash_ok} = expression_info(op, specs)

    case take_prefix(uri, prefix) do
      {:ok, rest} -> match_plain(specs, sep, stops, slash_ok, rest, parts, params, budget - 1)
      :error -> {:nomatch, budget - 1}
    end
  end

  defp walk([{:exp, op, specs} | parts], uri, params, budget) when op in @named_ops do
    prefix = named_prefix(op)

    case uri do
      <<^prefix::binary-size(1), rest::binary>> ->
        match_named(op, specs, rest, parts, params, budget - 1)

      _other ->
        walk(parts, uri, params, budget)
    end
  end

  defp expression_info(op, specs) do
    {prefix, sep, stops} = base_info(op)
    stops = if length(specs) > 1, do: Enum.uniq([sep | stops]), else: stops
    slash_ok = op in [:reserved, :fragment]
    {prefix, sep, stops, slash_ok}
  end

  @comma ?,

  defp base_info(:simple), do: {nil, @comma, [?/, ??, ?#]}
  defp base_info(:reserved), do: {nil, @comma, [?#]}
  defp base_info(:fragment), do: {"#", @comma, [?#]}
  defp base_info(:label), do: {".", ?., [?., ?/, ??, ?#]}
  defp base_info(:path), do: {"/", ?/, [?/, ??, ?#]}

  defp named_prefix(:param), do: ";"
  defp named_prefix(:query), do: "?"
  defp named_prefix(:cont), do: "&"

  defp match_plain([{name, :plain}], _sep, stops, slash_ok, uri, next_parts, params, budget) do
    last_value(name, uri, stops, slash_ok, next_parts, params, budget)
  end

  defp match_plain(
         [{name, :plain} | specs],
         sep,
         stops,
         slash_ok,
         uri,
         next_parts,
         params,
         budget
       ) do
    case scan_stops(uri, stops, budget) do
      :budget ->
        :budget

      {:ok, len, byte, budget} ->
        if byte == sep and len >= 1 do
          raw = binary_part(uri, 0, len)
          rest = binary_part(uri, len + 1, byte_size(uri) - len - 1)

          case put_raw(params, name, raw, slash_ok, budget) do
            {:ok, params, budget} ->
              match_plain(specs, sep, stops, slash_ok, rest, next_parts, params, budget)

            {:nomatch, budget} ->
              {:nomatch, budget}

            :budget ->
              :budget
          end
        else
          {:nomatch, budget}
        end
    end
  end

  defp last_value(name, uri, stops, slash_ok, [{:lit, lit} | _] = next_parts, params, budget) do
    case scan_stops(uri, stops, budget) do
      :budget ->
        :budget

      {:ok, max_len, _byte, budget} ->
        case positions(uri, lit, max_len, budget) do
          :budget ->
            :budget

          {:ok, candidates, budget} ->
            try_positions(candidates, uri, name, next_parts, params, budget, slash_ok)
        end
    end
  end

  defp last_value(name, uri, stops, slash_ok, [{:exp, op, _} | _] = next_parts, params, budget)
       when op in @prefix_ops do
    char = prefix_char(op)

    cond do
      char in stops ->
        last_value_plain(name, uri, stops, slash_ok, next_parts, params, budget)

      op in @named_ops ->
        last_value_plain(name, uri, [char | stops], slash_ok, next_parts, params, budget)

      true ->
        case scan_stops(uri, stops, budget) do
          :budget ->
            :budget

          {:ok, max_len, _byte, budget} ->
            case positions(uri, <<char>>, max_len, budget) do
              :budget ->
                :budget

              {:ok, candidates, budget} ->
                try_positions(candidates, uri, name, next_parts, params, budget, slash_ok)
            end
        end
    end
  end

  defp last_value(name, uri, stops, slash_ok, next_parts, params, budget) do
    last_value_plain(name, uri, stops, slash_ok, next_parts, params, budget)
  end

  defp last_value_plain(name, uri, stops, slash_ok, next_parts, params, budget) do
    case scan_stops(uri, stops, budget) do
      :budget ->
        :budget

      {:ok, len, _byte, budget} ->
        if len >= 1 do
          raw = binary_part(uri, 0, len)
          rest = binary_part(uri, len, byte_size(uri) - len)

          case put_raw(params, name, raw, slash_ok, budget) do
            {:ok, params, budget} -> walk(next_parts, rest, params, budget)
            {:nomatch, budget} -> {:nomatch, budget}
            :budget -> :budget
          end
        else
          {:nomatch, budget}
        end
    end
  end

  defp prefix_char(:fragment), do: ?#
  defp prefix_char(:label), do: ?.
  defp prefix_char(:path), do: ?/
  defp prefix_char(:param), do: ?;
  defp prefix_char(:query), do: ??
  defp prefix_char(:cont), do: ?&

  defp try_positions([], _uri, _name, _next_parts, _params, budget, _slash_ok),
    do: {:nomatch, budget}

  defp try_positions([pos | positions], uri, name, next_parts, params, budget, slash_ok) do
    raw = binary_part(uri, 0, pos)
    rest = binary_part(uri, pos, byte_size(uri) - pos)

    case put_raw(params, name, raw, slash_ok, budget) do
      {:ok, params, budget} ->
        case walk(next_parts, rest, params, budget) do
          {:ok, params, budget} ->
            {:ok, params, budget}

          {:nomatch, budget} ->
            try_positions(positions, uri, name, next_parts, params, budget, slash_ok)

          :budget ->
            :budget
        end

      {:nomatch, budget} ->
        try_positions(positions, uri, name, next_parts, params, budget, slash_ok)

      :budget ->
        :budget
    end
  end

  defp match_named(op, specs, rest, next_parts, params, budget) when op in [:query, :cont] do
    case scan_stops(rest, [?#], budget) do
      :budget ->
        :budget

      {:ok, len, _byte, budget} ->
        segment = binary_part(rest, 0, len)
        after_query = binary_part(rest, len, byte_size(rest) - len)
        names = MapSet.new(spec_names(specs))

        case spend(budget, byte_size(segment)) do
          :budget ->
            :budget

          {:ok, budget} ->
            case query_pairs(:binary.split(segment, "&", [:global]), names, params, budget) do
              {:ok, params, budget} -> walk(next_parts, after_query, params, budget)
              {:nomatch, budget} -> {:nomatch, budget}
              :budget -> :budget
            end
        end
    end
  end

  defp match_named(:param, specs, rest, next_parts, params, budget) do
    names = MapSet.new(spec_names(specs))
    extra = named_extra_stops(next_parts)
    future = following_names(next_parts)

    # Each pair holds one ';' at its start, also the first pair: this
    # rebuild gives back the ';' that the walk took as the prefix of the
    # expression. A pair that belongs to the next {;...} expression goes
    # back to the walk with its ';'.
    #
    case param_pairs(<<?;, rest::binary>>, names, params, budget, extra, future) do
      {:ok, params, budget, rest} -> walk(next_parts, rest, params, budget)
      {:nomatch, budget} -> {:nomatch, budget}
      :budget -> :budget
    end
  end

  defp named_extra_stops([{:exp, :cont, _} | _]), do: [?&]
  defp named_extra_stops(_next_parts), do: []

  # Only the names of a next {;...} expression can hold a ';' pair. A
  # ';name=value' pair never belongs to a {?...} or a {&...} expression,
  # so the names of these expressions are not future names: the walk of
  # the pairs ignores a pair with such a name.
  #
  defp following_names([{:exp, :param, specs} | _]), do: MapSet.new(spec_names(specs))

  defp following_names(_next_parts), do: nil

  defp query_pairs([], _names, params, budget), do: {:ok, params, budget}

  defp query_pairs([pair | pairs], names, params, budget) do
    case spend(budget, byte_size(pair)) do
      :budget ->
        :budget

      {:ok, budget} ->
        {raw_name, raw_value} =
          case :binary.split(pair, "=") do
            [name] -> {name, ""}
            [name, value] -> {name, value}
          end

        case known_name(raw_name, names, budget) do
          {:ok, name, budget} ->
            if Map.has_key?(params, name) do
              {:nomatch, budget}
            else
              case put_raw(params, name, raw_value, true, budget) do
                {:ok, params, budget} -> query_pairs(pairs, names, params, budget)
                {:nomatch, budget} -> {:nomatch, budget}
                :budget -> :budget
              end
            end

          {:unknown, budget} ->
            query_pairs(pairs, names, params, budget)

          :budget ->
            :budget
        end
    end
  end

  # One call holds the pairs that start with exactly one ';'. The first
  # pair and the pairs after it use the same code.
  #
  defp param_pairs(<<?;, body::binary>>, names, params, budget, extra, future) do
    if budget <= 0 do
      :budget
    else
      stops = [?=, ?;, ?/, ??, ?# | extra]

      case scan_stops(body, stops, budget) do
        :budget ->
          :budget

        # A pair with no name (';;', or a ';' at the end of the URI) is
        # not a valid pair: the URI does not match.
        #
        {:ok, 0, _byte, budget} ->
          {:nomatch, budget}

        {:ok, name_len, _byte, budget} ->
          raw_name = binary_part(body, 0, name_len)
          after_name = binary_part(body, name_len, byte_size(body) - name_len)

          case scan_value(after_name, extra, budget) do
            :budget ->
              :budget

            {raw_value, body_rest, budget} ->
              case known_name(raw_name, names, budget) do
                {:ok, name, budget} ->
                  if Map.has_key?(params, name) do
                    {:nomatch, budget}
                  else
                    case put_raw(params, name, raw_value, false, budget) do
                      {:ok, params, budget} ->
                        param_next(body_rest, names, params, budget, extra, future)

                      {:nomatch, budget} ->
                        {:nomatch, budget}

                      :budget ->
                        :budget
                    end
                  end

                {:unknown, budget} ->
                  case future_name?(raw_name, future, budget) do
                    :budget -> :budget
                    {true, budget} -> {:ok, params, budget, <<?;, body::binary>>}
                    {false, budget} -> param_next(body_rest, names, params, budget, extra, future)
                  end

                :budget ->
                  :budget
              end
          end
      end
    end
  end

  defp param_next(<<?;, _rest::binary>> = body_rest, names, params, budget, extra, future),
    do: param_pairs(body_rest, names, params, budget, extra, future)

  defp param_next(body_rest, _names, params, budget, _extra, _future),
    do: {:ok, params, budget, body_rest}

  defp scan_value(<<?=, after_eq::binary>>, extra, budget) do
    case scan_stops(after_eq, [?;, ?/, ??, ?# | extra], budget) do
      :budget ->
        :budget

      {:ok, value_len, _byte, budget} ->
        value = binary_part(after_eq, 0, value_len)
        rest = binary_part(after_eq, value_len, byte_size(after_eq) - value_len)
        {value, rest, budget}
    end
  end

  defp scan_value(after_name, _extra, budget), do: {"", after_name, budget}

  defp future_name?(_raw_name, nil, budget), do: {false, budget}

  defp future_name?(raw_name, future, budget) do
    case spend(budget, byte_size(raw_name)) do
      :budget ->
        :budget

      {:ok, budget} ->
        member? =
          case decode(raw_name) do
            {:ok, name} -> MapSet.member?(future, name)
            :error -> false
          end

        {member?, budget}
    end
  end

  defp known_name(raw_name, names, budget) do
    case spend(budget, byte_size(raw_name)) do
      :budget ->
        :budget

      {:ok, budget} ->
        case decode(raw_name) do
          {:ok, name} ->
            if MapSet.member?(names, name), do: {:ok, name, budget}, else: {:unknown, budget}

          :error ->
            {:unknown, budget}
        end
    end
  end

  defp spec_names(specs), do: Enum.map(specs, fn {name, _modifier} -> name end)

  defp put_raw(params, name, raw, slash_ok, budget) do
    if budget <= 0 do
      :budget
    else
      case check_raw(raw, slash_ok, budget - 1) do
        {:ok, budget} -> {:ok, Map.put(params, name, raw), budget}
        {:nomatch, budget} -> {:nomatch, budget}
        :budget -> :budget
      end
    end
  end

  # One scan of the raw bytes of a value. A '%' must be followed by two
  # hex digits. The triplet %2F decodes to '/': when the operator of the
  # expression does not let '/' cross, it gives no match. The values are
  # decoded one time at the end of the walk (decode_params/2).
  #
  defp check_raw(<<>>, _slash_ok, budget), do: {:ok, budget}

  defp check_raw(<<?%, hi, lo, rest::binary>>, slash_ok, budget) do
    case spend(budget, 3) do
      :budget ->
        :budget

      {:ok, budget} ->
        case hex_byte(hi, lo) do
          {:ok, 0x2F} when not slash_ok -> {:nomatch, budget}
          {:ok, _byte} -> check_raw(rest, slash_ok, budget)
          :error -> {:nomatch, budget}
        end
    end
  end

  defp check_raw(<<?%, _rest::binary>>, _slash_ok, budget), do: {:nomatch, budget}
  defp check_raw(<<?%>>, _slash_ok, budget), do: {:nomatch, budget}

  defp check_raw(<<_byte, rest::binary>>, slash_ok, budget) do
    case spend(budget, 1) do
      :budget -> :budget
      {:ok, budget} -> check_raw(rest, slash_ok, budget)
    end
  end

  defp decode_params(raw_params, budget) do
    total = Enum.reduce(raw_params, 0, fn {_name, raw}, acc -> acc + byte_size(raw) end)

    case spend(budget, total) do
      :budget ->
        :budget

      {:ok, _budget} ->
        decode_all(Map.to_list(raw_params), %{})
    end
  end

  defp decode_all([], params), do: {:ok, params}

  defp decode_all([{name, raw} | rest], params) do
    case decode(raw) do
      {:ok, value} -> decode_all(rest, Map.put(params, name, value))
      :error -> :nomatch
    end
  end

  @doc false
  @spec decode(binary()) :: {:ok, String.t()} | :error
  def decode(value) do
    with {:ok, binary} <- unescape(value, <<>>),
         true <- String.valid?(binary) do
      {:ok, binary}
    else
      _error -> :error
    end
  end

  defp unescape(<<>>, acc), do: {:ok, acc}

  defp unescape(<<?%, hi, lo, rest::binary>>, acc) do
    case hex_byte(hi, lo) do
      {:ok, byte} -> unescape(rest, <<acc::binary, byte>>)
      :error -> :error
    end
  end

  defp unescape(<<?%, _rest::binary>>, _acc), do: :error
  defp unescape(<<byte, rest::binary>>, acc), do: unescape(rest, <<acc::binary, byte>>)

  defp hex_byte(hi, lo) do
    case {hex_digit(hi), hex_digit(lo)} do
      {{:ok, hi}, {:ok, lo}} -> {:ok, hi * 16 + lo}
      _error -> :error
    end
  end

  defp hex_digit(byte) when byte in ?0..?9, do: {:ok, byte - ?0}
  defp hex_digit(byte) when byte in ?a..?f, do: {:ok, byte - ?a + 10}
  defp hex_digit(byte) when byte in ?A..?F, do: {:ok, byte - ?A + 10}
  defp hex_digit(_byte), do: :error

  # One scan of the URI for the stop bytes. The scan costs one unit for
  # each byte that it examines. The scan stops at the budget, so the work
  # of one match never goes over the budget.
  #
  defp scan_stops(uri, stops, budget), do: scan_stops(uri, stops, budget, 0)

  defp scan_stops(<<byte, rest::binary>>, stops, budget, len) do
    case spend(budget, 1) do
      :budget ->
        :budget

      {:ok, budget} ->
        if byte in stops do
          {:ok, len, byte, budget}
        else
          scan_stops(rest, stops, budget, len + 1)
        end
    end
  end

  defp scan_stops(<<>>, _stops, budget, len), do: {:ok, len, nil, budget}

  # The positions of the next literal (or of the prefix character of the
  # next expression) are searched only in the first
  # max_len + byte_size(needle) bytes of the URI. The search costs one
  # unit for each byte of the scope.
  #
  defp positions(uri, needle, max_len, budget) do
    limit = min(max_len + byte_size(needle), byte_size(uri))

    case spend(budget, limit) do
      :budget ->
        :budget

      {:ok, budget} ->
        candidates =
          uri
          |> :binary.matches(needle, scope: {0, limit})
          |> Enum.map(fn {pos, _length} -> pos end)
          |> Enum.filter(fn pos -> pos >= 1 and pos <= max_len end)
          |> Enum.reverse()

        {:ok, candidates, budget}
    end
  end

  defp take_prefix(uri, nil), do: {:ok, uri}

  defp take_prefix(uri, prefix) do
    size = byte_size(prefix)

    case uri do
      <<^prefix::binary-size(size), rest::binary>> -> {:ok, rest}
      _other -> :error
    end
  end

  defp spend(budget, units) when units > budget, do: :budget
  defp spend(budget, units), do: {:ok, budget - units}
end
