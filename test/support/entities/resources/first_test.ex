defmodule Support.Entities.Resources.FirstTest do
  use OzMcp.Config.Resource, dsl?: false

  alias OzMcp.Structs.{Annotations, ReadResourceResult, Resource, TextResourceContents}

  def list do
    list = [
      %Resource{}
      |> Resource.uri("file:///marketing.md")
      |> Resource.name("marketing.md")
      |> Resource.title("Marketing rules")
      |> Resource.description("All detailed marketing rules")
      |> Resource.mime_type("text/markdown")
      |> Resource.annotations(
        %Annotations{}
        |> Annotations.audience(["user"])
        |> Annotations.priority(1)
      )
    ]

    list
  end

  def read(_ctx, %{"uri" => "file:///marketing.md"} = _params) do
    result =
      %ReadResourceResult{}
      |> ReadResourceResult.contents([
        %TextResourceContents{}
        |> TextResourceContents.uri("file:///marketing.md")
        |> TextResourceContents.mime_type("text/markdown")
        |> TextResourceContents.text("# Marketing rules")
      ])
      |> ReadResourceResult.build()

    {:ok, result}
  end
end
