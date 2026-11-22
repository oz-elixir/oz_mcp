defmodule OzMcp.Structs.RootTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.Root

  test "builds a root" do
    result =
      %Root{}
      |> Root.uri("file:///home/user/project")
      |> Root.name("Project")
      |> Root._meta(%{"k" => "v"})
      |> Root.build()

    assert result == %{uri: "file:///home/user/project", name: "Project", _meta: %{"k" => "v"}}
  end

  test "the name is optional" do
    assert Root.build(Root.uri(%Root{}, "file:///a")) == %{uri: "file:///a"}
  end

  test "requires a file:// uri" do
    assert_raise ArgumentError, ~r/'uri'/, fn -> Root.build(%Root{}) end

    assert_raise ArgumentError, ~r/file:\/\//, fn ->
      Root.build(Root.uri(%Root{}, "https://example.com"))
    end
  end

  test "rejects an empty name" do
    assert_raise ArgumentError, ~r/'name'/, fn ->
      %Root{uri: "file:///a"} |> Root.name("") |> Root.build()
    end
  end
end
