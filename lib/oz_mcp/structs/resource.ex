defmodule OzMcp.Structs.Resource do
  @moduledoc """
  Helper module used to build `Resource` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %Resource{}
    |> Resource.uri("file:///logs/app.log")
    |> Resource.name("app.log")
    |> Resource.build()
  ```

  Result:

  ```elixir
  %{name: "app.log", uri: "file:///logs/app.log"}
  ```

  ## Long example:

  ```elixir
  %Resource{}
    |> Resource.uri("file:///logs/app.log")
    |> Resource.name("app.log")
    |> Resource.title("Application log")
    |> Resource.description("Main application log file")
    |> Resource.mime_type("text/plain")
    |> Resource.size(1024)
    |> Resource.annotations(
      %Annotations{}
      |> Annotations.audience(["assistant"])
    )
    |> Resource.build()
  ```

  Result:

  ```elixir
  %{
    name: "app.log",
    size: 1024,
    description: "Main application log file",
    title: "Application log",
    uri: "file:///logs/app.log",
    annotations: %{audience: ["assistant"]},
    mimeType: "text/plain"
  }
  ```

  The `required_scopes` field holds the scopes that a principal must hold to
  use the resource. OzMcp uses them for the check of `resources/read` and
  `resources/subscribe` and for the filter of `resources/list`. They are
  never sent to the client.

  Specification: [Resource](https://modelcontextprotocol.io/specification/2025-11-25/schema#resource)
  """

  use OzMcp.Structs.Wire,
    fields: [
      uri: {:uri, required: true},
      name: {:string, required: true},
      title: :string,
      description: :string,
      mimeType: :string,
      _meta: :meta,
      icons: {:list_of, OzMcp.Structs.Icon},
      annotations: {:struct, OzMcp.Structs.Annotations},
      size: :non_neg_integer,
      required_scopes: :scopes,
      extras: :extras
    ]
end
