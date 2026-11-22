#
# An internal module of lib/ is `@moduledoc false`, so the docs hide it
# and the docs group only the public modules. A public doc or a guide
# names an internal module without backticks: ExDoc makes a link of a
# name in backticks, and a link to a hidden module is a broken link.
# `mix docs --warnings-as-errors` finds such a link, but not in the
# files of `skip_undefined_reference_warnings_on`, so this test reads
# them all.
#
defmodule OzMcp.HiddenModulesDocsTest do
  use ExUnit.Case, async: true

  # A name in backticks: `Mod`, `Mod.fun/1`, `Mod.t()`, `m:Mod`,
  # `t:Mod.t/0`. The capture is the full module name, so a public
  # submodule of a hidden module does not match. ExDoc makes no link of
  # a struct (`%Mod{}`), so a name after `%` does not match.
  #
  @backticked ~r/`[^`\n]*?(?<![\w.%])(OzMcp(?:\.[A-Z]\w*)*)(?![\w]|\.[A-Z])[^`\n]*`/

  setup_all do
    {hidden, public} =
      Application.spec(:oz_mcp, :modules)
      |> Enum.filter(&in_lib?/1)
      |> Enum.split_with(&match?({:docs_v1, _, _, _, :hidden, _, _}, Code.fetch_docs(&1)))

    %{hidden: MapSet.new(hidden, &inspect/1), public: public}
  end

  test "each public module is in a named group of the docs", %{public: public} do
    groups = Mix.Project.config()[:docs][:groups_for_modules]

    assert public != []

    for module <- public do
      assert Enum.any?(groups, fn {_group, match} -> in_group?(module, match) end),
             "#{inspect(module)} has a moduledoc but no group of mix.exs lists it"
    end
  end

  test "no public doc and no guide links to a hidden module", %{hidden: hidden, public: public} do
    texts =
      for module <- public, {where, text} <- docs(module) do
        {where, text}
      end

    files =
      for file <- ["README.md" | Path.wildcard("guides/**/*.md")] do
        {file, File.read!(file)}
      end

    links =
      for {where, text} <- texts ++ files,
          [snippet, module] <- Regex.scan(@backticked, text),
          module in hidden do
        "#{where}: #{snippet}"
      end

    assert links == [],
           "these docs put a hidden module in backticks (write the name without them):\n" <>
             Enum.join(links, "\n")
  end

  defp docs(module) do
    {:docs_v1, _anno, _language, _format, moduledoc, _metadata, docs} = Code.fetch_docs(module)

    entries =
      for {{kind, name, arity}, _anno, _signature, doc, _metadata} <- docs do
        {"#{inspect(module)} #{kind} #{name}/#{arity}", doc}
      end

    for {where, %{"en" => text}} <- [{inspect(module), moduledoc} | entries] do
      {where, text}
    end
  end

  # The test env also compiles bench/support into the application.
  #
  defp in_lib?(module) do
    source = to_string(module.module_info(:compile)[:source])
    String.starts_with?(source, Path.join(File.cwd!(), "lib/"))
  end

  defp in_group?(module, %Regex{} = regex), do: Regex.match?(regex, inspect(module))
  defp in_group?(module, modules) when is_list(modules), do: module in modules
end
