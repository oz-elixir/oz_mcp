defmodule Support.Entities.Templates.SecondTest do
  use OzMcp.Config.Template, dsl?: false

  alias OzMcp.Structs.{ReadResourceResult, ResourceTemplate, TextResourceContents}
  alias OzMcp.Utils.Error

  def list do
    list = [
      %ResourceTemplate{}
      |> ResourceTemplate.name("Archive documents")
      |> ResourceTemplate.uri_template("file://archives/{year}/{name}")
      |> ResourceTemplate.title("Archives collection")
      |> ResourceTemplate.description("Archives collection description")
      |> ResourceTemplate.mime_type("text/markdown"),
      %ResourceTemplate{}
      |> ResourceTemplate.name("Notes documents")
      |> ResourceTemplate.uri_template("file://notes/{topic}")
      |> ResourceTemplate.title("Notes collection")
      |> ResourceTemplate.description("Notes collection description")
      |> ResourceTemplate.mime_type("text/markdown")
    ]

    list
  end

  def read(_ctx, params, "file://archives/{year}/{name}", uri_params) do
    if params["uri"] == "file://archives/2024/missing.md" do
      #
      # Simulate an error
      #
      error = Error.new(-32000, "resource temporarily unavailable")
      {:error, error}
    else
      result =
        %ReadResourceResult{}
        |> ReadResourceResult.contents([
          %TextResourceContents{}
          |> TextResourceContents.uri(params["uri"])
          |> TextResourceContents.mime_type("text/markdown")
          |> TextResourceContents.text(
            "# Archive year: #{uri_params["year"]}, name: #{uri_params["name"]}"
          )
        ])
        |> ReadResourceResult.build()

      {:ok, result}
    end
  end

  def read(_ctx, params, "file://notes/{topic}", uri_params) do
    result =
      %ReadResourceResult{}
      |> ReadResourceResult.contents([
        %TextResourceContents{}
        |> TextResourceContents.uri(params["uri"])
        |> TextResourceContents.mime_type("text/markdown")
        |> TextResourceContents.text("# Note topic: #{uri_params["topic"]}")
      ])
      |> ReadResourceResult.build()

    {:ok, result}
  end
end
