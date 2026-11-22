#
# A tool module with `dsl?: false` that returns five plain maps and tells a
# test process which list calls it gets. A test registers its process as
# `:tool_counting_probe`. The module has no scope, so a protected server
# must keep the plain path of the lists: the catalog is read, `list/0` is
# not called again.
#
defmodule Support.Entities.Tools.CountingTest do
  use OzMcp.Config.Tool, dsl?: false, warn?: false

  @tools for i <- 1..5,
             do: %{
               "name" => "plain#{i}",
               "description" => "A plain tool",
               "inputSchema" => %{"type" => "object"}
             }

  def list do
    notify(:list)
    @tools
  end

  def call(_ctx, _params), do: {:ok, %{"content" => []}}

  defp notify(message) do
    case Process.whereis(:tool_counting_probe) do
      nil -> :ok
      pid -> send(pid, message)
    end
  end
end
