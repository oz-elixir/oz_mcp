#
# A resource module with `dsl?: false` whose list returns plain maps.
# The maps carry no `required_scopes`, so the filtered lists always
# show them.
#
defmodule Support.Entities.Resources.PlainMapTest do
  use OzMcp.Config.Resource, dsl?: false, warn?: false

  alias OzMcp.Structs.{ReadResourceResult, TextResourceContents}

  @resources [
    %{"uri" => "file:///plain-one.md", "name" => "plain-one.md", "mimeType" => "text/markdown"},
    %{"uri" => "file:///plain-two.md", "name" => "plain-two.md", "mimeType" => "text/markdown"}
  ]

  def list, do: @resources

  def read(_ctx, %{"uri" => uri} = _params) do
    result =
      %ReadResourceResult{}
      |> ReadResourceResult.contents([
        %TextResourceContents{}
        |> TextResourceContents.uri(uri)
        |> TextResourceContents.mime_type("text/markdown")
        |> TextResourceContents.text("# Content of #{uri}")
      ])
      |> ReadResourceResult.build()

    {:ok, result}
  end
end
