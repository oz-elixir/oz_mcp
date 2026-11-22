defmodule OzMcp.CommentFormatTest do
  use ExUnit.Case, async: true

  # The format of the comments and the moduledocs of lib/, test/, mix.exs
  # and bench/ (the rules of AGENTS.md, sections "Comments" and "Moduledoc").
  #
  # The line above a comment block decides its form: after a blank line
  # it is an open block (no first `#` line, a last `#` line), else it is a
  # framed block (a `#` line before and after its text). The comment above
  # a defmodule is always framed. A comment never sits right under a module
  # attribute (`@doc`, `@impl`, `@spec`...) nor inside the head of a
  # declaration.
  #
  # A banner or a heading of dashes has a blank line before
  # and after it and the line after a @moduledoc is blank.
  #
  @frame "#"
  @rule ~r/^# -{2,}$/
  @heading ~r/^# -{2,} \S/
  @heredoc_marker ~r/"""|'''/
  @moduledoc_heredoc ~r/^@moduledoc\s+(~[sS])?("""|''')/
  @moduledoc_line ~r/^@moduledoc\s+(~[sS])?"/
  @attribute ~r/^@[a-z_]+\b/

  @no_frame "a comment block needs a `#` line before and after its text"
  @no_open "a comment block after a blank line has no first `#` line and ends with a `#` line"
  @under_attribute "a comment never sits under a module attribute: put it above the declaration"
  @in_head "a comment never sits inside the head of a declaration: put it above the declaration"

  test "each comment block and each moduledoc of lib/, test/, mix.exs and bench/ has its format" do
    breaks =
      Enum.flat_map(
        Path.wildcard("lib/**/*.ex") ++
          Path.wildcard("bench/**/*.{ex,exs}") ++
          Path.wildcard("test/**/*.{ex,exs}") ++ ["mix.exs"],
        &check_file/1
      )

    assert breaks == [],
           "Comment format breaks:\n" <>
             Enum.map_join(breaks, "\n", fn {path, line, why} -> "#{path}:#{line}: #{why}" end)
  end

  test "an open block after a blank line passes" do
    assert check_lines(["", "# text", "#", "def f, do: :ok"]) == []
    assert check_lines(["", "# One.", "#", "# Two.", "#", "@doc false"]) == []
    assert check_lines(["  :ok", "", "# text", "#", ":not_running ->"]) == []
  end

  test "a framed block on the first line of a block or above a defmodule passes" do
    assert check_lines(["error ->", "#", "# text", "#", "if true do"]) == []
    assert check_lines(["rescue", "#", "# text", "#", "Error ->"]) == []
    assert check_lines(["#", "# text", "#", "defmodule OzMcp.Foo do"]) == []
    assert check_lines(["", "#", "# text", "#", "defmodule OzMcp.Foo do"]) == []
  end

  test "a comment block of the wrong form breaks" do
    assert check_lines(["", "#", "# text", "#", "def f, do: :ok"]) == [{2, @no_open}]
    assert check_lines(["", "# text", "def f, do: :ok"]) == [{2, @no_open}]
    assert check_lines(["error ->", "# text", "#", "if true do"]) == [{2, @no_frame}]
    assert check_lines(["", "# text", "#", "defmodule OzMcp.Foo do"]) == [{2, @no_frame}]
  end

  test "a comment under an attribute or inside the head of a declaration breaks" do
    assert check_lines(["@doc false", "#", "# text", "#", "def f, do: :ok"]) ==
             [{2, @under_attribute}]

    assert check_lines(["@impl true", "# text", "#", "def f, do: :ok"]) ==
             [{2, @under_attribute}]

    assert check_lines(["@max 64", "#", "# text", "#", "@min 1"]) ==
             [{2, @under_attribute}]

    assert check_lines(["def f(a),", "#", "# text", "#", "do: a"]) == [{2, @in_head}]
  end

  test "a banner, a separator and a heading pass" do
    assert check_lines([
             "error ->",
             "#",
             "# One paragraph.",
             "#",
             "# The second paragraph.",
             "#",
             "code"
           ]) == []

    assert check_lines([
             "# -------------------------------------------------------------------",
             "# A section",
             "# -------------------------------------------------------------------",
             "",
             "code"
           ]) == []

    assert check_lines(["", "# -----", "", "code"]) == []
    assert check_lines(["", "# -- A heading", "", "code"]) == []
    assert check_lines(["", "# ---- A heading ----", "", "code"]) == []
  end

  test "a comment block without its frame lines breaks" do
    assert check_lines(["# text", "code"]) == [{1, @no_open}]
    assert check_lines(["#", "# text", "code"]) == [{1, @no_open}]
    assert check_lines(["error ->", "# text", "code"]) == [{2, @no_frame}]
    assert check_lines(["error ->", "#", "# text", "code"]) == [{2, @no_frame}]

    assert check_lines([
             "",
             "#",
             "# -------------------------------------------------------------------",
             "# A section",
             "# -------------------------------------------------------------------",
             "#",
             "",
             "code"
           ]) == [{2, @no_open}]

    assert check_lines(["# text", "# ---- A heading ----", "code"]) == [{1, @no_open}]
  end

  test "a banner or a heading without a blank line around it breaks" do
    no_blank = "a banner or a heading needs a blank line before and after it"

    assert check_lines(["", "# -----", "# A section", "# -----", "code"]) ==
             [{2, no_blank}]

    assert check_lines(["code", "# -----", "", "code"]) == [{2, no_blank}]

    assert check_lines(["", "# ---- A heading ----", "code"]) == [{2, no_blank}]
    assert check_lines(["describe \"f/1\" do", "# -----", "code"]) == [{2, no_blank}]
  end

  test "a banner or a heading on the first line of a do block passes" do
    assert check_lines(["describe \"f/1\" do", "# -----", "# A section", "# -----", ""]) == []
    assert check_lines(["describe \"f/1\" do", "# ---- A heading", "", "code"]) == []
  end

  test "a moduledoc without a blank line after it breaks" do
    no_blank = "the line after @moduledoc must be blank"

    assert check_lines(["@moduledoc false", "alias OzMcp.Foo"]) == [{1, no_blank}]

    assert check_lines([
             "@moduledoc \"\"\"",
             "The module.",
             "\"\"\"",
             "alias OzMcp.Foo"
           ]) == [{3, no_blank}]

    assert check_lines(["@moduledoc \"One line.\"", "alias OzMcp.Foo"]) == [{1, no_blank}]
  end

  test "a hash line inside a heredoc or a sigil and a trailing comment, pass" do
    assert check_lines([
             "@doc \"\"\"",
             "# Not a comment.",
             "\"\"\"",
             "def f, do: :ok"
           ]) == []

    assert check_lines([
             "text = ~S\"\"\"",
             "# Not a comment.",
             "\"\"\"",
             "code"
           ]) == []

    assert check_lines([
             "text = ~S'''",
             "@moduledoc \"\"\"",
             "A fixture.",
             "\"\"\"",
             "# Not a comment.",
             "'''",
             "code"
           ]) == []

    assert check_lines(["x = 1 # text"]) == []
  end

  test "a blank line after each form of @moduledoc passes" do
    assert check_lines(["@moduledoc false", "", "alias OzMcp.Foo"]) == []
    assert check_lines(["@moduledoc \"One line.\"", "", "alias OzMcp.Foo"]) == []

    assert check_lines([
             "@moduledoc \"\"\"",
             "The module.",
             "\"\"\"",
             "",
             "alias OzMcp.Foo"
           ]) == []
  end

  test "@doc is not a moduledoc and needs no blank line after it" do
    assert check_lines(["@doc false", "def f, do: :ok"]) == []

    assert check_lines([
             "@doc \"\"\"",
             "The function.",
             "\"\"\"",
             "def f, do: :ok"
           ]) == []
  end

  #
  # The checker reads the source as lines, not as an AST. It walks the
  # trimmed lines once: it marks the lines of a heredoc, collects each run
  # of comment lines outside a heredoc and checks the run and each
  # @moduledoc. A trailing comment (`code # text`) is not a comment block.
  #
  defp check_file(path) do
    lines = path |> File.read!() |> String.split("\n")

    for {line, why} <- check_lines(lines), do: {path, line, why}
  end

  defp check_lines(lines) do
    trimmed = Enum.map(lines, &String.trim/1)
    mask = heredoc_mask(trimmed)
    block_breaks(trimmed, mask) ++ moduledoc_breaks(trimmed, mask)
  end

  #
  # Gives one flag per line: true when the line is the text of a heredoc.
  # A `#` line outside a heredoc opens no heredoc. A heredoc ends only at
  # its own marker: a `"""` inside a `'''` heredoc does not end it. The
  # marker of a heredoc in the middle of a line outside a heredoc (in a
  # one-line sigil, for example) is rare and the checker treats it as the
  # opening of a heredoc.
  #
  defp heredoc_mask(lines) do
    {mask, _} =
      Enum.map_reduce(lines, nil, fn line, marker -> {marker != nil, toggle(line, marker)} end)

    mask
  end

  defp toggle(line, nil = _marker) do
    markers = Regex.scan(@heredoc_marker, line)

    if not String.starts_with?(line, "#") and rem(length(markers), 2) == 1,
      do: markers |> List.last() |> hd(),
      else: nil
  end

  defp toggle(line, marker),
    do: if(String.starts_with?(line, marker), do: nil, else: marker)

  defp starts_marker?(line),
    do: String.starts_with?(line, ~s(""")) or String.starts_with?(line, "'''")

  #
  # Collects each run of comment lines and checks the lines before and
  # after the run. The line before the first line of a file and the line
  # after its last line, count as blank.
  #
  defp block_breaks(lines, mask) do
    zipped = lines |> Enum.zip(mask) |> Enum.with_index(1)

    zipped
    |> runs()
    |> Enum.flat_map(fn {start, run, stop} ->
      case check_block(run, line_at(zipped, start - 1), line_at(zipped, stop + 1)) do
        :ok -> []
        {:error, why} -> [{start, why}]
      end
    end)
  end

  defp runs(zipped), do: collect_runs(zipped, [])

  defp collect_runs([], acc), do: Enum.reverse(acc)

  defp collect_runs([{{line, in_doc}, i} | rest], acc) do
    if comment?(line, in_doc) do
      {run, rest} = take_run(rest, [line])
      collect_runs(rest, [{i, Enum.reverse(run), i + length(run) - 1} | acc])
    else
      collect_runs(rest, acc)
    end
  end

  defp take_run([{{line, in_doc}, _} = item | rest], run) do
    if comment?(line, in_doc) do
      take_run(rest, [line | run])
    else
      {run, [item | rest]}
    end
  end

  defp take_run([], run), do: {run, []}

  defp line_at(zipped, index) do
    case Enum.find(zipped, fn {_, i} -> i == index end) do
      {{line, _}, _} -> line
      nil -> ""
    end
  end

  defp comment?(line, in_doc), do: String.starts_with?(line, "#") and not in_doc

  defp check_block(run, before, after_line) do
    cond do
      banner?(run) or heading?(run) ->
        blank_around(before, after_line)

      Regex.match?(@attribute, before) ->
        {:error, @under_attribute}

      String.ends_with?(before, ",") and String.starts_with?(after_line, "do:") ->
        {:error, @in_head}

      String.starts_with?(after_line, "defmodule ") ->
        form(framed?(run), @no_frame)

      before == "" ->
        form(open?(run), @no_open)

      true ->
        form(framed?(run), @no_frame)
    end
  end

  defp form(true, _why), do: :ok
  defp form(false, why), do: {:error, why}

  defp open?([first | _] = run) do
    length(run) >= 2 and first != @frame and List.last(run) == @frame and
      not Enum.any?(run, &rule?(&1))
  end

  defp framed?(run) do
    length(run) >= 3 and hd(run) == @frame and List.last(run) == @frame and
      Enum.any?(run, &(&1 != @frame)) and not Enum.any?(run, &rule?(&1))
  end

  defp banner?([first | rest]), do: rule?(first) and rule?(List.last(rest, first))

  defp heading?([line]), do: Regex.match?(@heading, line)
  defp heading?(_run), do: false

  defp rule?(line), do: Regex.match?(@rule, line)

  defp block_start?(line), do: String.ends_with?(line, " do") or line == "do"

  # A banner or a heading on the first line of a `do` block (a describe,
  # for example) has no blank line before it: the formatter removes one.
  #
  defp blank_around(before, after_line) do
    if (before == "" or block_start?(before)) and after_line == "",
      do: :ok,
      else: {:error, "a banner or a heading needs a blank line before and after it"}
  end

  #
  # Checks the line after each @moduledoc. A heredoc moduledoc is checked
  # at its closing `"""` line, the other forms at their own line.
  #
  defp moduledoc_breaks(lines, mask) do
    zipped = lines |> Enum.zip(mask) |> Enum.with_index(1)

    Enum.flat_map(zipped, fn
      {{_line, true}, _i} ->
        []

      {{line, false}, i} ->
        cond do
          line == "@moduledoc false" -> blank_after?(lines, i)
          Regex.match?(@moduledoc_heredoc, line) -> blank_after_closing?(lines, zipped, i)
          Regex.match?(@moduledoc_line, line) -> blank_after?(lines, i)
          true -> []
        end
    end)
  end

  defp blank_after?(lines, i) do
    case Enum.at(lines, i) do
      nil -> []
      "" -> []
      _line -> [{i, "the line after @moduledoc must be blank"}]
    end
  end

  defp blank_after_closing?(lines, zipped, opening) do
    closing =
      Enum.drop_while(zipped, fn {{line, in_doc}, i} ->
        i <= opening or not (in_doc and starts_marker?(line))
      end)

    case closing do
      [{{_line, _in_doc}, i} | _rest] -> blank_after?(lines, i)
      [] -> []
    end
  end
end
