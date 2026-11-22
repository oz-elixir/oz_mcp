defmodule OzMcp.Utils.TemplateUri.Parser do
  @moduledoc false

  @operators %{
    "+" => :reserved,
    "#" => :fragment,
    "." => :label,
    "/" => :path,
    ";" => :param,
    "?" => :query,
    "&" => :cont
  }

  @reserved_operators ["=", ",", "!", "@", "|"]

  @prefix_operators [:fragment, :label, :path, :param, :query, :cont]

  @max_expressions 16

  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse(template) when is_binary(template) do
    if String.valid?(template) do
      parse_valid(template)
    else
      {:error, "invalid UTF-8 at position #{invalid_utf8_position(template, 0)}"}
    end
  end

  defp parse_valid(template) do
    with {:ok, tokens} <- tokenize(template),
         :ok <- check_count(tokens),
         {:ok, located} <- build_parts(tokens),
         :ok <- check_unique_vars(located),
         :ok <- check_adjacent(located),
         :ok <- check_query_last(located) do
      {:ok, finish(template, located)}
    end
  end

  defp invalid_utf8_position(<<char::utf8, rest::binary>>, pos),
    do: invalid_utf8_position(rest, pos + byte_size(<<char::utf8>>))

  defp invalid_utf8_position(_rest, pos), do: pos

  defp tokenize(template), do: tokenize(template, 0, "", nil, [])

  defp tokenize("", _pos, lit, lit_pos, acc),
    do: {:ok, Enum.reverse(push_lit(acc, lit, lit_pos))}

  defp tokenize("{" <> rest, pos, lit, lit_pos, acc) do
    case String.split(rest, "}", parts: 2) do
      [body, tail] when body != "" ->
        if String.contains?(body, "{") do
          {:error, "unbalanced '{' at position #{pos}"}
        else
          tokenize(tail, pos + byte_size(body) + 2, "", nil, [
            {:exp, body, pos} | push_lit(acc, lit, lit_pos)
          ])
        end

      _ ->
        {:error, "empty or unclosed expression at position #{pos}"}
    end
  end

  defp tokenize("}" <> _, pos, _lit, _lit_pos, _acc),
    do: {:error, "unbalanced '}' at position #{pos}"}

  defp tokenize(<<char::utf8, rest::binary>>, pos, lit, lit_pos, acc) do
    lit_start = if lit == "", do: pos, else: lit_pos
    tokenize(rest, pos + byte_size(<<char::utf8>>), lit <> <<char::utf8>>, lit_start, acc)
  end

  defp tokenize(_invalid, pos, _lit, _lit_pos, _acc),
    do: {:error, "invalid UTF-8 at position #{pos}"}

  defp push_lit(acc, "", _pos), do: acc
  defp push_lit(acc, lit, pos), do: [{:lit, lit, pos} | acc]

  defp check_count(tokens) do
    Enum.reduce_while(tokens, {:ok, 0}, fn
      {:exp, _body, pos}, {:ok, count} when count >= @max_expressions ->
        {:halt, {:error, "more than #{@max_expressions} expressions at position #{pos}"}}

      {:exp, _body, _pos}, {:ok, count} ->
        {:cont, {:ok, count + 1}}

      {:lit, _lit, _pos}, ok ->
        {:cont, ok}

      _token, error ->
        {:halt, error}
    end)
    |> case do
      {:ok, _count} -> :ok
      error -> error
    end
  end

  defp build_parts(tokens) do
    tokens
    |> Enum.reduce_while({:ok, []}, fn
      {:lit, lit, pos}, {:ok, acc} ->
        {:cont, {:ok, [{{:lit, lit}, pos} | acc]}}

      {:exp, body, pos}, {:ok, acc} ->
        case build_exp(body, pos) do
          {:ok, exp} -> {:cont, {:ok, [{exp, pos} | acc]}}
          error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp build_exp(body, pos) do
    with {:ok, op, names_part} <- split_operator(body, pos),
         {:ok, names} <- parse_names(names_part, pos) do
      specs = Enum.map(names, fn name -> {name, :plain} end)
      {:ok, {:exp, op, specs}}
    end
  end

  defp split_operator(<<char::utf8, rest::binary>> = body, pos) do
    char = <<char::utf8>>

    cond do
      Map.has_key?(@operators, char) ->
        {:ok, Map.fetch!(@operators, char), rest}

      char in @reserved_operators ->
        {:error, "reserved operator '#{char}' at position #{pos}"}

      true ->
        {:ok, :simple, body}
    end
  end

  defp parse_names(names_part, pos) do
    names_part
    |> String.split(",")
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case check_name(name, pos) do
        :ok -> {:cont, {:ok, [name | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp check_name(name, pos) do
    cond do
      name == "" ->
        {:error, "empty expression at position #{pos}"}

      String.contains?(name, "*") ->
        {:error,
         "level 4 modifiers are not supported, use {+var} for a value with '/' at position #{pos}"}

      String.contains?(name, ":") ->
        {:error, "level 4 modifiers are not supported at position #{pos}"}

      invalid_name?(name) ->
        {:error, "invalid variable name #{inspect(name)} at position #{pos}"}

      true ->
        :ok
    end
  end

  defp invalid_name?(name) do
    chars = String.to_charlist(name)

    bad_char? =
      Enum.any?(chars, fn char ->
        not (char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char == ?_ or char == ?.)
      end)

    bad_dot? = hd(chars) == ?. or List.last(chars) == ?. or double_dot?(chars)

    bad_char? or bad_dot?
  end

  defp double_dot?([?. | [?. | _]]), do: true
  defp double_dot?([_ | rest]), do: double_dot?(rest)
  defp double_dot?([]), do: false

  defp check_unique_vars(located) do
    Enum.reduce_while(located, {:ok, MapSet.new()}, fn
      {{:lit, _lit}, _pos}, ok ->
        {:cont, ok}

      {{:exp, _op, specs}, pos}, {:ok, seen} ->
        case check_spec_names(specs, seen, pos) do
          {:ok, seen} -> {:cont, {:ok, seen}}
          error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, _seen} -> :ok
      error -> error
    end
  end

  defp check_spec_names(specs, seen, pos) do
    Enum.reduce_while(specs, {:ok, seen}, fn {name, _modifier}, {:ok, acc} ->
      if MapSet.member?(acc, name) do
        {:halt, {:error, "duplicate variable name #{inspect(name)} at position #{pos}"}}
      else
        {:cont, {:ok, MapSet.put(acc, name)}}
      end
    end)
  end

  defp check_adjacent(located) do
    located
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce_while(:ok, fn
      [{{:exp, op_a, _specs_a}, _pos_a}, {{:exp, op_b, _specs_b}, pos_b}], :ok ->
        cond do
          op_b not in @prefix_operators ->
            {:halt, {:error, "ambiguous adjacent expressions at position #{pos_b}"}}

          op_a == :param and op_b == :label ->
            {:halt, {:error, "ambiguous adjacent expressions at position #{pos_b}"}}

          true ->
            {:cont, :ok}
        end

      _pair, :ok ->
        {:cont, :ok}
    end)
  end

  defp check_query_last(located), do: check_query_last(located, false)

  defp check_query_last([], _in_query), do: :ok

  defp check_query_last([{part, pos} | rest], in_query) do
    case {part, in_query} do
      {{:exp, :query, _specs}, false} ->
        check_query_last(rest, true)

      {{:exp, :cont, _specs}, false} ->
        check_query_last(rest, true)

      {_part, false} ->
        check_query_last(rest, false)

      {{:exp, :fragment, _specs}, true} ->
        check_query_last(rest, true)

      {_part, true} ->
        {:error, "only {#...} may follow {?...} or {&...} at position #{pos}"}
    end
  end

  defp finish(template, located) do
    parts = Enum.map(located, fn {part, _pos} -> part end)

    %{
      template: template,
      prefix: prefix(parts),
      vars: vars(parts),
      shape: shape(parts),
      parts: parts
    }
  end

  defp prefix([{:lit, lit} | _rest]), do: lit
  defp prefix(_parts), do: ""

  defp vars(parts) do
    Enum.flat_map(parts, fn
      {:exp, _op, specs} -> Enum.map(specs, fn {name, _modifier} -> name end)
      {:lit, _lit} -> []
    end)
  end

  defp shape(parts) do
    parts
    |> Enum.map(&shape_part/1)
    |> IO.iodata_to_binary()
  end

  defp shape_part({:lit, lit}), do: lit

  defp shape_part({:exp, op, specs}) do
    names =
      if op in [:param, :query, :cont] do
        specs
        |> Enum.map(fn {name, _modifier} -> name end)
        |> Enum.sort()
      else
        Enum.map(specs, fn _spec -> "#" end)
      end

    "{" <> operator_char(op) <> Enum.join(names, ",") <> "}"
  end

  defp operator_char(:simple), do: ""
  defp operator_char(:reserved), do: "+"
  defp operator_char(:fragment), do: "#"
  defp operator_char(:label), do: "."
  defp operator_char(:path), do: "/"
  defp operator_char(:param), do: ";"
  defp operator_char(:query), do: "?"
  defp operator_char(:cont), do: "&"
end
