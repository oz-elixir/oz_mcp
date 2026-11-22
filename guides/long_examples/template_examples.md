# Template examples

Long examples of the guide [Templates](../entities/templates.md). Each
example uses the rules of that guide and this page does not repeat them.

## The DSL

This example shows each macro of the DSL and the optional
`complete/4` callback for one variable:

```elixir
defmodule MyApp.Templates.EngineeringTemplate do
  use OzMcp.Config.Template

  alias OzMcp.Structs.{CompleteResult, Completion, ReadResourceResult, TextResourceContents}

  template "File documents" do
    uri_template "file://docs/{path}"
    title "Documents collection"
    description "The documents of the project, by path"
    mime_type "text/markdown"
    required_scopes ["docs:read"]

    annotations do
      audience ["assistant"]
      priority 0.5
      last_modified "2026-10-01T09:00:00Z"
    end

    icon do
      src "https://assets.example.com/docs.svg"
      mime_type "image/svg+xml"
      sizes ["any"]
    end

    meta :rsc_id, "13dGCUNxDVewiNC"
  end

  template "Database users" do
    uri_template "db://user/{userId}"
    title "User informations"
    description "The record of one user"
    mime_type "application/json"
  end

  @impl true
  def read(_ctx, %{"uri" => uri}, "file://docs/{path}", %{"path" => path}) do
    {:ok, text_result(uri, "text/markdown", "# Document #{path}")}
  end

  def read(_ctx, %{"uri" => uri}, "db://user/{userId}", %{"userId" => user_id}) do
    {:ok, text_result(uri, "application/json", ~s({"id":"#{user_id}"}))}
  end

  @impl true
  def complete(_ctx, "db://user/{userId}", %{"name" => "userId", "value" => prefix}, _context) do
    values =
      ["u-100", "u-101", "u-200"]
      |> Enum.filter(&String.starts_with?(&1, prefix))

    {:ok,
     %CompleteResult{}
     |> CompleteResult.completion(
       %Completion{}
       |> Completion.values(values)
       |> Completion.total(length(values))
       |> Completion.has_more(false)
     )
     |> CompleteResult.build()}
  end

  def complete(_ctx, _uri, _argument, _context) do
    {:ok, %{completion: %{values: []}}}
  end

  defp text_result(uri, mime_type, text) do
    %ReadResourceResult{}
    |> ReadResourceResult.contents([
      %TextResourceContents{}
      |> TextResourceContents.uri(uri)
      |> TextResourceContents.mime_type(mime_type)
      |> TextResourceContents.text(text)
    ])
    |> ReadResourceResult.build()
  end
end
```

Each `read/4` clause matches on the `uri_template`. The clause that
matches gives the contents for the URIs of that template.

The first clause of `complete/4` matches the URI template
`db://user/{userId}`. Each other reference gets the second clause with
an empty list of values. The guide about completions gives the details
of the `complete/4` callback.

## Way 2: data

This example shows one template in the two forms, with the nested
values. The structs carry `required_scopes`, so the list
methods of the server filter the list of the module:

```elixir
defmodule MyApp.Templates.DataEngineeringTemplate do
  use OzMcp.Config.Template, dsl?: false

  alias OzMcp.Structs.{Annotations, Icon, ResourceTemplate}

  @impl true
  def list, do: templates()

  @impl true
  def read(_ctx, %{"uri" => uri}, "file://struct-docs/{path}", %{"path" => path}) do
    {:ok, %{contents: [%{uri: uri, mimeType: "text/markdown", text: "# Document #{path}"}]}}
  end

  defp templates() do
    [
      %ResourceTemplate{}
      |> ResourceTemplate.uri_template("file://struct-docs/{path}")
      |> ResourceTemplate.name("File documents")
      |> ResourceTemplate.title("Documents collection")
      |> ResourceTemplate.description("The documents of the project, by path")
      |> ResourceTemplate.mime_type("text/markdown")
      |> ResourceTemplate.required_scopes(["docs:read"])
      |> ResourceTemplate.annotations(
        %Annotations{}
        |> Annotations.audience(["assistant"])
        |> Annotations.priority(0.5)
        |> Annotations.last_modified("2026-10-01T09:00:00Z")
      )
      |> ResourceTemplate.icons([
        %Icon{}
        |> Icon.src("https://assets.example.com/docs.svg")
        |> Icon.mime_type("image/svg+xml")
        |> Icon.sizes(["any"])
      ])
      |> ResourceTemplate._meta(%{rsc_id: "13dGCUNxDVewiNC"})
    ]
  end
end
```

The same template as a map with the wire keys:

```elixir
%{
  uriTemplate: "file://docs/{path}",
  name: "File documents",
  title: "Documents collection",
  description: "The documents of the project, by path",
  mimeType: "text/markdown",
  required_scopes: ["docs:read"],
  annotations: %{audience: ["assistant"], priority: 0.5, lastModified: "2026-10-01T09:00:00Z"},
  icons: [%{src: "https://assets.example.com/docs.svg", mimeType: "image/svg+xml", sizes: ["any"]}],
  _meta: %{rsc_id: "13dGCUNxDVewiNC"}
}
```
