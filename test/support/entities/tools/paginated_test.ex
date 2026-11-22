# Test support modules for server-level pagination tests.
#
# The three tool modules mirror the tmp/mcp_ex reference counts (3/3/5).
# One loop builds them in the manual style, so `list/0` is explicit.
#

for {module, prefix, count} <- [
      {Support.Entities.Tools.PaginatedAlphaTest, "alpha", 3},
      {Support.Entities.Tools.PaginatedBetaTest, "beta", 3},
      {Support.Entities.Tools.PaginatedGammaTest, "gamma", 5}
    ] do
  defmodule module do
    use OzMcp.Config.Tool, dsl?: false

    alias OzMcp.Structs.Tool
    alias OzMcp.Utils.Error

    @tools for i <- 1..count, do: Tool.name(%Tool{}, "#{prefix}_#{i}")

    def list, do: @tools
    def call(_ctx, _params), do: {:error, Error.new(-32601, "tool not found")}
  end
end
