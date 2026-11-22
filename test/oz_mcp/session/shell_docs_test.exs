#
# The shell of the session holds the callbacks and the runner of the
# effects only. The rules live in the pure modules of the core and the
# head comment of the shell points to each one.
# See: lib/oz_mcp/session.ex
#
defmodule OzMcp.Session.ShellDocsTest do
  use ExUnit.Case, async: true

  @shell "lib/oz_mcp/session.ex"

  @pure_modules [
    "OzMcp.Session.Core",
    "OzMcp.Session.Requests",
    "OzMcp.Session.Outbound",
    "OzMcp.Session.Route",
    "OzMcp.Session.Streams",
    "OzMcp.Session.Streams.Post",
    "OzMcp.Session.Streams.Get",
    "OzMcp.Session.Roots",
    "OzMcp.Session.Subscriptions",
    "OzMcp.Session.Persistence",
    "OzMcp.Session.Effect",
    "OzMcp.Session.Effects"
  ]

  setup do
    %{source: File.read!(@shell)}
  end

  test "the shell stays small", %{source: source} do
    assert length(String.split(source, "\n")) < 600
  end

  test "the head comment points to each pure module", %{source: source} do
    for module <- @pure_modules do
      assert source =~ module
    end
  end
end
