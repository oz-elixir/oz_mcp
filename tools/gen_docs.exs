defmodule OzMcpDocs do
  @moduledoc false

  alias OzMcp.Instance.Config.Check
  alias OzMcp.Instance.Config.Schema

  @guide "guides/runtime/runtime_options.md"
  @start "<!-- generated:options -->"
  @stop "<!-- /generated:options -->"

  def options_table do
    rows =
      for {key, _type, default, flags} = row <- Schema.rows(), key != :allowed_origins do
        "| `#{key}` | `#{inspect(default)}`#{unit(flags)} | #{check(row)} |"
      end

    Enum.join(["| Option | Default | Check at boot |", "|---|---|---|" | rows], "\n")
  end

  # `Check.describe/1` has no clause for the type `:custom`.
  #
  defp check({_key, :custom, _default, _flags}), do: "see the list below"
  defp check(row), do: Check.describe(row)

  def render(guide) do
    [head, rest] = String.split(guide, @start, parts: 2)
    [_old, tail] = String.split(rest, @stop, parts: 2)
    head <> @start <> "\n\n" <> options_table() <> "\n\n" <> @stop <> tail
  end

  def main do
    guide = File.read!(@guide)
    rendered = render(guide)

    cond do
      "--check" in System.argv() and rendered != guide ->
        IO.puts(:stderr, "#{@guide} is stale: run mix docs")
        System.halt(1)

      rendered != guide ->
        File.write!(@guide, rendered)
        IO.puts("updated #{@guide}")

      true ->
        :ok
    end
  end

  defp unit(flags), do: if(u = flags[:unit], do: " #{u}", else: "")
end

if Mix.env() == :dev do
  OzMcpDocs.main()
end
