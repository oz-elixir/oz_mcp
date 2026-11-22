defmodule OzMcp.ReadmeTest do
  use ExUnit.Case, async: true

  @readme Path.join(File.cwd!(), "README.md")

  test "the README is the main page of the documentation" do
    docs = Mix.Project.config()[:docs]

    assert docs[:main] == "readme"
    assert "README.md" in docs[:extras]
  end

  test "each relative link of the README points to a file that exists" do
    readme = File.read!(@readme)

    links =
      Regex.scan(~r{\]\(([^)]+)\)}, readme)
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.reject(fn target ->
        String.starts_with?(target, "#") or Regex.match?(~r{^[a-zA-Z][a-zA-Z0-9+.-]*://}, target)
      end)

    assert links == Enum.uniq(links)

    Enum.each(links, fn target ->
      assert File.exists?(Path.expand(target, File.cwd!())), "dead link: #{target}"
    end)
  end
end
