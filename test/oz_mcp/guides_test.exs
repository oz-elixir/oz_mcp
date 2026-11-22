defmodule OzMcp.GuidesTest do
  #
  # Sync: the tests write files under tmp/ and compile modules at run time.
  #
  use ExUnit.Case, async: false

  @guides Path.wildcard("guides/**/*.md")
  @skip "<!-- guides-test: skip -->"
  @out Path.join(File.cwd!(), "tmp/guides_test")

  test "each Elixir example of the guides compiles with no warning" do
    File.rm_rf!(@out)
    File.mkdir_p!(@out)

    files =
      for guide <- @guides,
          {code, index} <- Enum.with_index(blocks(File.read!(guide))) do
        path = Path.join(@out, "#{Path.basename(guide, ".md")}_#{index}.ex")
        File.write!(path, code)
        path
      end

    {result, stderr} = compile(files)

    assert {:ok, modules, %{compile_warnings: [], runtime_warnings: []}} = result,
           "the examples of the guides do not compile\n" <> stderr

    assert modules == Enum.uniq(modules)

    on_exit(fn ->
      Enum.each(modules, fn module ->
        :code.purge(module)
        :code.delete(module)
      end)
    end)
  end

  # A guide that is not in the extras of `mix.exs` is not in the docs and a
  # guide with no link in the README is hard to find. The README links to
  # the HexDocs page of the guide: hex.pm does not rewrite a relative link
  # and the guides are not in the package.
  #
  test "each guide is in the docs extras and in the README" do
    mix_exs = File.read!("mix.exs")
    readme = File.read!("README.md")

    for guide <- @guides do
      url = "https://oz-mcp.hexdocs.pm/#{Path.basename(guide, ".md")}.html"

      assert mix_exs =~ ~s{"#{guide}"}, "#{guide} is not in the extras of mix.exs"
      assert readme =~ "](#{url})", "#{guide} has no link to #{url} in the README"
    end
  end

  # The examples of one guide compile together with the examples of the
  # other guides, so a block can use the modules of another block. The
  # module names must be unique across all the guides.
  #
  defp compile([]), do: {{:ok, [], %{compile_warnings: [], runtime_warnings: []}}, ""}

  defp compile(files) do
    ExUnit.CaptureIO.with_io(:stderr, fn ->
      Kernel.ParallelCompiler.compile(files, return_diagnostics: true)
    end)
  end

  # The fenced elixir blocks that start with defmodule and that do not
  # follow the skip marker. Use the marker only for an extract that cannot
  # compile alone.
  #
  defp blocks(markdown) do
    ~r/(<!-- guides-test: skip -->\s*)?```elixir\n(.*?)```/s
    |> Regex.scan(markdown)
    |> Enum.flat_map(fn
      [_all, @skip <> _, _code] -> []
      [_all, _marker, "defmodule" <> _ = code] -> [code]
      _other -> []
    end)
  end
end
