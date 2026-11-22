#
# Template module of the end-to-end suite for the URI template
# operators: one template for each operator that the suite checks (a
# simple variable, a reserved string, a query continuation and a path
# continuation). The `read/4` callback answers with the uri params as
# JSON, so a test asserts the decoded values and it reports each call
# to the probe process of the instance: the test registers itself under
# the name `Module.concat(instance, "TemplateProbe")`, so the tests of
# the file run in parallel.
#
defmodule Support.Entities.Templates.Rfc6570Test do
  use OzMcp.Config.Template, warn?: false

  alias OzMcp.Structs.{
    CompleteResult,
    Completion,
    ReadResourceResult,
    TextResourceContents
  }

  template "Users" do
    uri_template "app://users/{id}"
    title "Users"
    description "Users template"
  end

  template "Files" do
    uri_template "file:///{+path}"
    title "Files"
    description "Files template"
  end

  template "Search" do
    uri_template "app://search{?q,page}"
    title "Search"
    description "Search template"
  end

  template "Api" do
    uri_template "app://api{/ver,id}"
    title "Api"
    description "Api template"
  end

  def read(ctx, params, "app://users/{id}", uri_params), do: reply(ctx, params, uri_params)
  def read(ctx, params, "file:///{+path}", uri_params), do: reply(ctx, params, uri_params)

  def read(ctx, params, "app://search{?q,page}", uri_params), do: reply(ctx, params, uri_params)
  def read(ctx, params, "app://api{/ver,id}", uri_params), do: reply(ctx, params, uri_params)

  def complete(_ctx, "file:///{+path}", %{"name" => "path"}, _context) do
    completion = %Completion{} |> Completion.values(["intro.md", "index.md"])

    {:ok,
     %CompleteResult{}
     |> CompleteResult.completion(completion)
     |> CompleteResult.build()}
  end

  defp probe(ctx), do: Module.concat(ctx.instance, "TemplateProbe")

  defp reply(ctx, params, uri_params) do
    case Process.whereis(probe(ctx)) do
      nil -> :ok
      pid -> send(pid, {:read_called, uri_params})
    end

    result =
      %ReadResourceResult{}
      |> ReadResourceResult.contents([
        %TextResourceContents{}
        |> TextResourceContents.uri(params["uri"])
        |> TextResourceContents.mime_type("text/plain")
        |> TextResourceContents.text(JSON.encode!(uri_params))
      ])
      |> ReadResourceResult.build()

    {:ok, result}
  end
end
