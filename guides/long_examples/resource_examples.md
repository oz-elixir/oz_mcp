# Resource examples

Long examples of the guide [Resources](../entities/resources.md). Each
example uses the rules of that guide and this page does not repeat them.

## The DSL

This example shows each macro of the DSL. The module declares one
resource with text contents and one resource with blob contents:

```elixir
defmodule MyApp.Resources.EngineeringResource do
  use OzMcp.Config.Resource

  alias OzMcp.Structs.{BlobResourceContents, ReadResourceResult, TextResourceContents}

  resource "definitions.md" do
    uri "file:///definitions.md"
    title "Project definitions list"
    description "The definitions of the words of the project"
    mime_type "text/markdown"
    size 2364
    required_scopes ["docs:read"]

    annotations do
      audience ["user", "assistant"]
      priority 0.8
      last_modified "2026-10-01T09:00:00Z"
    end

    icon do
      src "https://assets.example.com/definitions-light.svg"
      mime_type "image/svg+xml"
      sizes ["any"]
      theme "light"
    end

    icon do
      src "https://assets.example.com/definitions-dark.svg"
      mime_type "image/svg+xml"
      sizes ["any"]
      theme "dark"
    end

    meta "owner", "engineering"
    meta :sha256, "4c0a39ec1661ddf125fa6b52ae7c5117e8eca71a867d29eea3f79aebecad11a3"
  end

  resource "logo.png" do
    uri "file:///logo.png"
    title "Logo of the project"
    description "The logo of the project, as a PNG image"
    mime_type "image/png"

    annotations do
      audience ["user"]
      priority 0.2
    end
  end

  @impl true
  def read(_ctx, %{"uri" => "file:///definitions.md" = uri}) do
    result =
      %ReadResourceResult{}
      |> ReadResourceResult.contents([
        %TextResourceContents{}
        |> TextResourceContents.uri(uri)
        |> TextResourceContents.mime_type("text/markdown")
        |> TextResourceContents.text("# Definitions\n\n- MCP: Model Context Protocol")
      ])
      |> ReadResourceResult.build()

    {:ok, result}
  end

  def read(_ctx, %{"uri" => "file:///logo.png" = uri}) do
    result =
      %ReadResourceResult{}
      |> ReadResourceResult.contents([
        %BlobResourceContents{}
        |> BlobResourceContents.uri(uri)
        |> BlobResourceContents.mime_type("image/png")
        |> BlobResourceContents.blob(Base.encode64(<<137, 80, 78, 71>>))
      ])
      |> ReadResourceResult.build()

    {:ok, result}
  end
end
```

The example shows the two parts of a `read/2` callback: a text
content and a blob content (Base64). A URI that no resource declares
never reaches `read/2`: the framework answers the error `-32002`.

## Way 2: data

This example shows one resource in the two forms, with the nested
values. The structs carry `required_scopes`, so the list
methods of the server filter the list of the module:

```elixir
defmodule MyApp.Resources.DataEngineeringResource do
  use OzMcp.Config.Resource, dsl?: false

  alias OzMcp.Structs.{Annotations, Icon, ReadResourceResult, Resource, TextResourceContents}

  @impl true
  def list, do: resources()

  @impl true
  def read(_ctx, %{"uri" => uri}) do
    {:ok,
     %ReadResourceResult{}
     |> ReadResourceResult.contents([
       %TextResourceContents{}
       |> TextResourceContents.uri(uri)
       |> TextResourceContents.mime_type("text/markdown")
       |> TextResourceContents.text("# Definitions")
     ])
     |> ReadResourceResult.build()}
  end

  defp resources() do
    [
      %Resource{}
      |> Resource.uri("file:///struct-definitions.md")
      |> Resource.name("struct-definitions.md")
      |> Resource.title("Project definitions list")
      |> Resource.description("The definitions of the words of the project")
      |> Resource.mime_type("text/markdown")
      |> Resource.size(2364)
      |> Resource.required_scopes(["docs:read"])
      |> Resource.annotations(
        %Annotations{}
        |> Annotations.audience(["user", "assistant"])
        |> Annotations.priority(0.8)
        |> Annotations.last_modified("2026-10-01T09:00:00Z")
      )
      |> Resource.icons([
        %Icon{}
        |> Icon.src("https://assets.example.com/definitions-light.svg")
        |> Icon.mime_type("image/svg+xml")
        |> Icon.sizes(["any"])
        |> Icon.theme("light")
      ])
      |> Resource._meta(%{owner: "engineering"})
    ]
  end
end
```

The same resource as a map with the wire keys:

```elixir
%{
  uri: "file:///definitions.md",
  name: "definitions.md",
  title: "Project definitions list",
  description: "The definitions of the words of the project",
  mimeType: "text/markdown",
  size: 2364,
  required_scopes: ["docs:read"],
  annotations: %{
    audience: ["user", "assistant"],
    priority: 0.8,
    lastModified: "2026-10-01T09:00:00Z"
  },
  icons: [
    %{
      src: "https://assets.example.com/definitions-light.svg",
      mimeType: "image/svg+xml",
      sizes: ["any"],
      theme: "light"
    }
  ],
  _meta: %{owner: "engineering"}
}
```
