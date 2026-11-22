defmodule Support.Entities.Templates.ScopedTest do
  use OzMcp.Config.Template, warn?: false

  alias OzMcp.Structs.{
    CompleteResult,
    Completion,
    ReadResourceResult,
    TextResourceContents
  }

  def read(_ctx, _rpc_params, _uri_template, _uri_params) do
    result =
      %ReadResourceResult{}
      |> ReadResourceResult.contents([
        %TextResourceContents{}
        |> TextResourceContents.mime_type("text/markdown")
        |> TextResourceContents.text("# Document")
      ])
      |> ReadResourceResult.build()

    {:ok, result}
  end

  def complete(_ctx, _ref, _argument, _context) do
    completion = %Completion{} |> Completion.values([])

    {:ok,
     %CompleteResult{}
     |> CompleteResult.completion(completion)
     |> CompleteResult.build()}
  end

  template "File documents" do
    uri_template "file:///docs/{name}"
    title "Documents"
    description "Documents that need the write scope"
    mime_type "text/markdown"
    required_scopes(["files:write"])
  end
end
