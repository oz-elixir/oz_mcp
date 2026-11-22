defmodule Support.Entities.Templates.FirstTest do
  use OzMcp.Config.Template, dsl?: false

  alias OzMcp.Structs.{
    CompleteResult,
    Completion,
    ReadResourceResult,
    ResourceTemplate,
    TextResourceContents
  }

  alias OzMcp.Utils.Error

  def list do
    list = [
      %ResourceTemplate{}
      |> ResourceTemplate.name("File documents")
      |> ResourceTemplate.uri_template("file://docs/{path}")
      |> ResourceTemplate.title("Documents collection")
      |> ResourceTemplate.description("Documents collection description")
      |> ResourceTemplate.mime_type("text/markdown")
    ]

    list
  end

  def read(_ctx, params, "file://docs/{path}", uri_params) do
    #
    # NOTE: In real case search the dynamic document using the 'path' parameter.
    # (maybe on database or filesystem).
    #
    if params["uri"] == "file://docs/missing.md" do
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
          |> TextResourceContents.text("# Doc path: #{uri_params["path"]}")
        ])
        |> ReadResourceResult.build()

      {:ok, result}
    end
  end

  def complete(_ctx, "file://docs/" <> _ref, %{"name" => "path"}, _context) do
    completion = %Completion{} |> Completion.values(["intro.md", "index.md"])

    {:ok,
     %CompleteResult{}
     |> CompleteResult.completion(completion)
     |> CompleteResult.build()}
  end
end
