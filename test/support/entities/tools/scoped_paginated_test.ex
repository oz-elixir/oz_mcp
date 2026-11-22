#
# Five tools for the tests of the lists that are filtered by scope:
#
#   * `t1` and `t3` need no scope,
#   * `t2` and `t5` need `files:write`,
#   * `t4` needs `admin`.
#
# The verifier of the tests gives `files:write` to one token and `admin`
# to no token, so each page of the filtered list can be pinned exactly.
#
defmodule Support.Entities.Tools.ScopedPaginatedTest do
  use OzMcp.Config.Tool, warn?: false

  alias OzMcp.Structs.{CallToolResult, TextContent}

  tool "t1" do
    title "T1"
    description "A tool with no scope"
  end

  tool "t2" do
    title "T2"
    description "A tool that needs the write scope"
    required_scopes(["files:write"])
  end

  tool "t3" do
    title "T3"
    description "A tool with no scope"
  end

  tool "t4" do
    title "T4"
    description "A tool that needs the admin scope"
    required_scopes(["admin"])
  end

  tool "t5" do
    title "T5"
    description "A tool that needs the write scope"
    required_scopes(["files:write"])
  end

  def call(_ctx, %{"name" => name} = _params) do
    result =
      %CallToolResult{}
      |> CallToolResult.content([
        %TextContent{}
        |> TextContent.text("#{name} ran")
      ])
      |> CallToolResult.build()

    {:ok, result}
  end
end
