# Test support modules for server-level pagination tests.
#
# The three prompt modules mirror the tmp/mcp_ex reference counts (3/3/5).
# One loop builds them in the manual style, so `list/0` is explicit.
#

for {module, prefix, count} <- [
      {Support.Entities.Prompts.PaginatedAlphaTest, "alpha", 3},
      {Support.Entities.Prompts.PaginatedBetaTest, "beta", 3},
      {Support.Entities.Prompts.PaginatedGammaTest, "gamma", 5}
    ] do
  defmodule module do
    use OzMcp.Config.Prompt, dsl?: false

    alias OzMcp.Structs.Prompt
    alias OzMcp.Utils.Error

    @prompts for i <- 1..count, do: Prompt.name(%Prompt{}, "#{prefix}_#{i}")

    def list, do: @prompts
    def get(_ctx, _params), do: {:error, Error.new(-32601, "prompt not found")}
  end
end
