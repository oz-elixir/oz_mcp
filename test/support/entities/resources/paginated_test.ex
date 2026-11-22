# Test support modules for server-level pagination tests.
#
# The three resource modules mirror the tmp/mcp_ex reference counts (3/3/5).
# One loop builds them in the manual style, so `list/0` is explicit.
#

for {module, prefix, count} <- [
      {Support.Entities.Resources.PaginatedAlphaTest, "alpha", 3},
      {Support.Entities.Resources.PaginatedBetaTest, "beta", 3},
      {Support.Entities.Resources.PaginatedGammaTest, "gamma", 5}
    ] do
  defmodule module do
    use OzMcp.Config.Resource, dsl?: false

    alias OzMcp.Structs.Resource
    alias OzMcp.Utils.Error

    resources =
      for i <- 1..count do
        %Resource{}
        |> Resource.uri("file:///#{prefix}/#{i}.md")
        |> Resource.name("#{prefix}_#{i}")
      end

    @resources resources

    def list, do: @resources

    def read(_ctx, _rpc_params),
      do: {:error, Error.new(-32000, "resource temporarily unavailable")}
  end
end
