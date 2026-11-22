#
# A tool module with `dsl?: false` whose list returns structs that carry
# scopes: the catalog holds them and the list methods filter on them.
#
defmodule Support.Entities.Tools.StructScopedTest do
  use OzMcp.Config.Tool, dsl?: false, warn?: false

  alias OzMcp.Structs.Tool

  @tools [
    %Tool{}
    |> Tool.name("open_struct")
    |> Tool.description("A struct with no scope")
    |> Tool.input_schema(%{"type" => "object"}),
    %Tool{}
    |> Tool.name("closed_struct")
    |> Tool.description("A struct that needs files:write")
    |> Tool.input_schema(%{"type" => "object"})
    |> Tool.required_scopes(["files:write"])
  ]

  def list, do: @tools

  def call(_ctx, _params), do: {:ok, %{"content" => []}}
end
