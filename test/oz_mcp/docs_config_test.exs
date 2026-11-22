defmodule OzMcp.DocsConfigTest do
  use ExUnit.Case, async: true

  test "the documentation opens on the readme" do
    config = docs_config()

    assert config[:main] == "readme"
    assert "README.md" in config[:extras]
    assert "CHANGELOG.md" in config[:extras]
  end

  test "each extra of the documentation exists" do
    for extra <- docs_config()[:extras] do
      assert File.exists?(extra), "the extras list names #{extra}, but the file does not exist"
    end
  end

  test "each module of the module groups exists" do
    for {group, modules} <- docs_config()[:groups_for_modules],
        is_list(modules),
        module <- modules do
      assert Code.ensure_loaded?(module),
             "the group #{inspect(group)} names the module #{inspect(module)}, " <>
               "but the module does not exist"
    end
  end

  test "the extras groups cover the folders of the guides" do
    groups = docs_config()[:groups_for_extras]

    for {group, regex} <- groups do
      assert is_struct(regex, Regex),
             "the extras group #{inspect(group)} must match the files of a folder of guides/"
    end
  end

  test "each guide file is in the extras of the documentation" do
    guides = Path.wildcard("guides/**/*.md")

    refute guides == [], "the project has no guide in guides/"

    for guide <- guides do
      assert guide in docs_config()[:extras],
             "the guide #{guide} is not in the extras list of the documentation"
    end
  end

  defp docs_config, do: Mix.Project.config() |> Keyword.fetch!(:docs)
end
