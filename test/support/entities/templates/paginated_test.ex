# Test support modules for server-level pagination tests.
#
# The three template modules mirror the tmp/mcp_ex reference counts (3/3/5).
# One loop builds them in the manual style, so `list/0` is explicit.
#

for {module, prefix, count} <- [
      {Support.Entities.Templates.PaginatedAlphaTest, "alpha", 3},
      {Support.Entities.Templates.PaginatedBetaTest, "beta", 3},
      {Support.Entities.Templates.PaginatedGammaTest, "gamma", 5}
    ] do
  defmodule module do
    use OzMcp.Config.Template, dsl?: false

    alias OzMcp.Structs.ResourceTemplate
    alias OzMcp.Utils.Error

    templates =
      for i <- 1..count do
        %ResourceTemplate{}
        |> ResourceTemplate.name("#{prefix}_#{i}")
        |> ResourceTemplate.uri_template("file:///#{prefix}/{#{String.first(prefix)}#{i}}")
      end

    @templates templates

    def list, do: @templates

    def read(_ctx, _rpc_params, _uri_template, _uri_params),
      do: {:error, Error.new(-32000, "resource temporarily unavailable")}
  end
end
