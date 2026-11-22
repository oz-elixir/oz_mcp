#
# Resources with and without `required_scopes`. The uri of the resource
# that was read is kept in :persistent_term, so the tests can pin whether
# the read callback ran (the framework runs a callback in its own
# process).
#
defmodule Support.Entities.Resources.ScopedTest do
  use OzMcp.Config.Resource, warn?: false

  alias OzMcp.Structs.{CompleteResult, Completion, ReadResourceResult, TextResourceContents}

  def read(_ctx, %{"uri" => uri} = _params) do
    :persistent_term.put({__MODULE__, :read}, uri)

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

  def complete(_ctx, _ref, _argument, _context) do
    completion = %Completion{} |> Completion.values([])

    {:ok,
     %CompleteResult{}
     |> CompleteResult.completion(completion)
     |> CompleteResult.build()}
  end

  resource "public.md" do
    uri "file:///public.md"
    title "Public notes"
    description "Notes that every principal can read"
    mime_type "text/markdown"
  end

  resource "secret.md" do
    uri "file:///secret.md"
    title "Secret notes"
    description "Notes that need the write scope"
    mime_type "text/markdown"
    required_scopes(["files:write"])
  end

  def reset, do: :persistent_term.put({__MODULE__, :read}, nil)

  def last_read, do: :persistent_term.get({__MODULE__, :read}, nil)
end
