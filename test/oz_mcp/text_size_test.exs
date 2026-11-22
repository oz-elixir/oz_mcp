defmodule OzMcp.TextSizeTest do
  use ExUnit.Case, async: true

  # The ceilings of the docs and comments of lib/ (rule: bench/README.md).
  # A change that needs more text raises a number in the same commit and
  # the commit message gives the reason. Comments say why, not what.
  #
  # 6,672 lines and a share rounded up to 0.267: 6,604 lines after the
  # dynamic entity modules, the schema cache and the list-changed
  # notifications went away, plus 62 lines for the docs of
  # `OzMcp.Testing`, 2 lines for the link to the Testing guide and 4
  # lines for the doc of `OzMcp.Testing.initialize_result/1`.
  #
  @max_text_lines 6_672
  @max_share 0.267

  setup_all do
    %{counts: Bench.TextSize.count(Bench.TextSize.files())}
  end

  test "the docs and comments of lib/ stay under the line ceiling", %{counts: counts} do
    text = counts.docs + counts.comments

    assert text <= @max_text_lines,
           "#{text} lines of docs and comments (ceiling: #{@max_text_lines}). " <>
             "Cut text, or raise @max_text_lines in the same commit and give the reason."
  end

  test "the share of docs and comments stays under the share ceiling", %{counts: counts} do
    share = Bench.TextSize.text_share(counts)

    assert share <= @max_share,
           "#{Float.round(share * 100, 1)}% of the non-blank lines are docs and comments " <>
             "(ceiling: #{Float.round(@max_share * 100, 1)}%)."
  end

  @tag :tmp_dir
  test "count/1 classifies docs, comments and code", %{tmp_dir: dir} do
    path = Path.join(dir, "fixture.ex")

    File.write!(path, ~S'''
    # Fixture module
    defmodule Fixture do
      @moduledoc """
      A fixture.

      It has a blank line.
      """

      @doc "One line."
      def one, do: :ok

      @doc false
      def hidden, do: :ok

      # A comment.
      def two, do: :ok

      #
      # A framed comment.
      #
      def three, do: :ok

      # -----
      # A banner comment.
      # -----

      def four, do: :ok
    end
    ''')

    assert Bench.TextSize.count([path]) == %{code: 8, docs: 5, comments: 4}
  end
end
