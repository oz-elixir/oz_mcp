defmodule OzMcp.Structs.ResourceTemplate do
  @moduledoc """
  Helper module used to build `ResourceTemplate` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %ResourceTemplate{}
    |> ResourceTemplate.uri_template("file:///{+path}")
    |> ResourceTemplate.name("Files")
    |> ResourceTemplate.build()
  ```

  Result:

  ```elixir
  %{name: "Files", uriTemplate: "file:///{+path}"}
  ```

  ## Long example:

  ```elixir
  %ResourceTemplate{}
    |> ResourceTemplate.uri_template("file:///{+path}")
    |> ResourceTemplate.name("Files")
    |> ResourceTemplate.title("Project files")
    |> ResourceTemplate.description("Access to project files")
    |> ResourceTemplate.mime_type("text/plain")
    |> ResourceTemplate.icons([
      %Icon{}
      |> Icon.src("https://img.com/icon.png")
      |> Icon.mime_type("image/png")
      |> Icon.sizes(["16x16"])
    ])
    |> ResourceTemplate.build()
  ```

  Result:

  ```elixir
  %{
    name: "Files",
    description: "Access to project files",
    title: "Project files",
    icons: [
      %{
        src: "https://img.com/icon.png",
        sizes: ["16x16"],
        mimeType: "image/png"
      }
    ],
    mimeType: "text/plain",
    uriTemplate: "file:///{+path}"
  }
  ```

  The `required_scopes` field holds the scopes that a principal must hold to
  use the template. OzMcp uses them for the check of `resources/read` and
  `resources/subscribe` and for the filter of `resources/templates/list`.
  They are never sent to the client.

  Specification: [ResourceTemplate](https://modelcontextprotocol.io/specification/2025-11-25/schema#resourcetemplate)
  """

  use OzMcp.Structs.Wire,
    fields: [
      name: {:string, required: true},
      title: :string,
      description: :string,
      mimeType: :string,
      _meta: :meta,
      icons: {:list_of, OzMcp.Structs.Icon},
      annotations: {:struct, OzMcp.Structs.Annotations},
      uriTemplate: {:string, required: true},
      required_scopes: :scopes,
      extras: :extras
    ]
end
