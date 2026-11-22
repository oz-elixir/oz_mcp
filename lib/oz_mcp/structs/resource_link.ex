defmodule OzMcp.Structs.ResourceLink do
  @moduledoc """
  Helper module used to build `ResourceLink` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %ResourceLink{}
    |> ResourceLink.uri("file:///logs/app.log")
    |> ResourceLink.name("app.log")
    |> ResourceLink.build()
  ```

  Result:

  ```elixir
  %{name: "app.log", type: "resource_link", uri: "file:///logs/app.log"}
  ```

  ## Long example:

  ```elixir
  %ResourceLink{}
    |> ResourceLink.uri("file:///logs/app.log")
    |> ResourceLink.name("app.log")
    |> ResourceLink.title("Application log")
    |> ResourceLink.description("Main application log file")
    |> ResourceLink.mime_type("text/plain")
    |> ResourceLink.size(1024)
    |> ResourceLink.annotations(
      %Annotations{}
      |> Annotations.audience(["assistant"])
    )
    |> ResourceLink.build()
  ```

  Result:

  ```elixir
  %{
    name: "app.log",
    size: 1024,
    type: "resource_link",
    description: "Main application log file",
    title: "Application log",
    uri: "file:///logs/app.log",
    annotations: %{audience: ["assistant"]},
    mimeType: "text/plain"
  }
  ```

  Specification: [ResourceLink](https://modelcontextprotocol.io/specification/2025-11-25/schema#resourcelink)
  """

  use OzMcp.Structs.Wire,
    const: %{type: "resource_link"},
    fields: [
      uri: {:uri, required: true, absolute: false},
      name: {:string, required: true},
      title: :string,
      description: :string,
      mimeType: :string,
      _meta: :meta,
      icons: {:list_of, OzMcp.Structs.Icon},
      annotations: {:struct, OzMcp.Structs.Annotations},
      size: :non_neg_integer
    ]

  alias OzMcp.Structs.{Keys, Validate}

  @doc false
  @spec check_map(map()) :: :ok
  def check_map(block) do
    uri = Keys.get(block, "uri", :uri, "")
    Validate.non_empty_string(:uri, uri)

    Validate.non_empty_string(:name, Keys.get(block, "name", :name, ""))
    Validate.non_empty_string_or_nil(:title, Keys.get(block, "title", :title, nil))

    Validate.non_empty_string_or_nil(
      :description,
      Keys.get(block, "description", :description, nil)
    )

    Validate.non_empty_string_or_nil(:mimeType, Keys.get(block, "mimeType", :mimeType, nil))
    Validate.meta(:_meta, Keys.get(block, "_meta", :_meta, nil))
    Validate.icons(Keys.get(block, "icons", :icons, nil))
    Validate.annotations(Keys.get(block, "annotations", :annotations, nil))
    Validate.non_neg_integer_or_nil(:size, Keys.get(block, "size", :size, nil))
  end
end
