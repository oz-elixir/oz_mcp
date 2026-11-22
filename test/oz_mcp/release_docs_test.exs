defmodule OzMcp.ReleaseDocsTest do
  use ExUnit.Case, async: true

  test "the README and the guides mount the router with the instance option" do
    for file <- ["README.md" | Path.wildcard("guides/**/*.md")] do
      refute File.read!(file) =~ "init_opts: [server:", "#{file} uses the old option"
    end
  end

  test "the docs groups list the public modules of the instance" do
    groups = Mix.Project.config()[:docs][:groups_for_modules]
    listed = groups |> Keyword.values() |> Enum.filter(&is_list/1) |> List.flatten()

    for module <- [OzMcp, OzMcp.Sessions, OzMcp.Tasks, OzMcp.PubSub, OzMcp.Pipeline.Bound] do
      assert module in listed
    end
  end
end
