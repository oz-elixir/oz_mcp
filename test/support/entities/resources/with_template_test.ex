defmodule Support.Entities.Resources.WithTemplateTest do
  use OzMcp.Config.Resource, dsl?: false

  alias OzMcp.Structs.{ReadResourceResult, Resource, TextResourceContents}

  # -----------------------------------------------------------------------
  # Resources
  # -----------------------------------------------------------------------

  def list do
    list = [
      %Resource{}
      |> Resource.uri("file:///definitions.md")
      |> Resource.name("definitions.md")
      |> Resource.title("Project definitions list")
      |> Resource.description("Project definitions list")
      |> Resource.mime_type("text/markdown")
    ]

    list
  end

  def read(_ctx, %{"uri" => "file:///definitions.md"} = _params) do
    result =
      %ReadResourceResult{}
      |> ReadResourceResult.contents([
        %TextResourceContents{}
        |> TextResourceContents.uri("file:///definitions.md")
        |> TextResourceContents.mime_type("text/markdown")
        |> TextResourceContents.text("# The is the list of definitions.")
      ])
      |> ReadResourceResult.build()

    {:ok, result}
  end
end
