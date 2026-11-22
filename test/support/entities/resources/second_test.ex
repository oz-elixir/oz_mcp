defmodule Support.Entities.Resources.SecondTest do
  use OzMcp.Config.Resource, dsl?: false

  alias OzMcp.Structs.{ReadResourceResult, Resource, TextResourceContents}
  alias OzMcp.Utils.Error

  def list do
    list = [
      %Resource{}
      |> Resource.uri("file:///definitions.md")
      |> Resource.name("definitions.md")
      |> Resource.title("Project definitions list")
      |> Resource.description("Project definitions list")
      |> Resource.mime_type("text/markdown"),
      %Resource{}
      |> Resource.uri("file:///api_call.md")
      |> Resource.name("api_call.md")
      |> Resource.title("Description of API call")
      |> Resource.description("Description of API call")
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

  def read(_ctx, %{"uri" => "file:///api_call.md"} = _params) do
    error = Error.new(-32000, "resource temporarily unavailable")
    {:error, error}
  end
end
