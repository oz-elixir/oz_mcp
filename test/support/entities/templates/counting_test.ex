#
# A template module with `dsl?: false` that returns one plain map and tells
# a test process which list calls it gets. A test registers its process as
# `:tool_counting_probe`, the probe of `Support.Entities.Tools.CountingTest` and reads the
# `:template_list` messages. The module has no scope, so the lists
# of the server keep the plain path.
#
defmodule Support.Entities.Templates.CountingTest do
  use OzMcp.Config.Template, dsl?: false, warn?: false

  @templates [
    %{
      "name" => "plain-template",
      "description" => "A plain template",
      "uriTemplate" => "file:///plain/{name}",
      "mimeType" => "text/markdown"
    }
  ]

  def list do
    notify(:template_list)
    @templates
  end

  def read(_ctx, _params, _uri_template, _uri_params), do: {:error, :not_found}

  defp notify(message) do
    case Process.whereis(:tool_counting_probe) do
      nil -> :ok
      pid -> send(pid, message)
    end
  end
end
