#
# The meter of the text of `lib/`: the code, doc and comment lines of the
# files.
#
defmodule Bench.TextSize do
  #
  # The rule of `count/1` is in `bench/README.md`. A doc line is a non-blank
  # line of a `@moduledoc`, `@doc` or `@typedoc` heredoc, with its opening and
  # closing line, or a one-line `@moduledoc`, `@doc` or `@typedoc` string. A
  # comment line starts with `#` and has text: a line that is only `#`, or
  # only `#` and dashes, is a frame and is not counted. All other non-blank
  # lines are code.
  #
  @type counts :: %{
          code: non_neg_integer(),
          docs: non_neg_integer(),
          comments: non_neg_integer()
        }

  @heredoc ~r/^@(moduledoc|doc|typedoc)\s+(~[sS])?"""/
  @one_line ~r/^@(moduledoc|doc|typedoc)\s+(~[sS])?"/
  @frame_rule ~r/^# -{2,}$/

  # Counts the code, doc and comment lines of the files.
  #
  @spec count([Path.t()]) :: counts()
  def count(paths) do
    Enum.reduce(paths, %{code: 0, docs: 0, comments: 0}, fn path, acc ->
      path
      |> File.stream!()
      |> Enum.map(&String.trim/1)
      |> classify(acc, false)
    end)
  end

  # The files of `lib/` that the meter reads.
  #
  @spec files() :: [Path.t()]
  def files, do: Path.wildcard("lib/**/*.ex")

  # The share of the docs and comments of the non-blank lines.
  #
  @spec text_share(counts()) :: float()
  def text_share(%{code: code, docs: docs, comments: comments}),
    do: (docs + comments) / (code + docs + comments)

  defp classify([], acc, _in_doc), do: acc
  defp classify(["" | rest], acc, in_doc), do: classify(rest, acc, in_doc)

  defp classify([line | rest], acc, true = _in_doc) do
    classify(rest, bump(acc, :docs), not String.starts_with?(line, ~s(""")))
  end

  defp classify([line | rest], acc, false = _in_doc) do
    cond do
      Regex.match?(@heredoc, line) ->
        classify(rest, bump(acc, :docs), true)

      Regex.match?(@one_line, line) ->
        classify(rest, bump(acc, :docs), false)

      frame?(line) ->
        classify(rest, acc, false)

      String.starts_with?(line, "#") ->
        classify(rest, bump(acc, :comments), false)

      true ->
        classify(rest, bump(acc, :code), false)
    end
  end

  # A frame line carries no text and costs no maintenance, as a blank line:
  # the meter must not reward its removal.
  #
  defp frame?(line), do: line == "#" or Regex.match?(@frame_rule, line)

  defp bump(acc, key), do: Map.update!(acc, key, &(&1 + 1))
end
