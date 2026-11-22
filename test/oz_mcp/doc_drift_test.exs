defmodule OzMcp.DocDriftTest do
  use ExUnit.Case, async: true

  defp flat(path), do: path |> File.read!() |> String.replace(~r/\s+/, " ")

  test "a request before the server starts gets 503 in the docs" do
    for file <- ["README.md", "guides/introduction/getting_started.md"] do
      refute flat(file) =~ ~r/before the server starts gets (the status )?`500`/,
             "#{file} says 500, the router answers 503"
    end
  end
end
