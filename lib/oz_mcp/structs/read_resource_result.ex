defmodule OzMcp.Structs.ReadResourceResult do
  @moduledoc """
  Helper module used to build `ReadResourceResult` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %ReadResourceResult{}
    |> ReadResourceResult.contents([
      %TextResourceContents{}
      |> TextResourceContents.uri("file:///logs/app.log")
      |> TextResourceContents.text("INFO App started")
    ])
    |> ReadResourceResult.build()
  ```

  Result:

  ```elixir
  %{contents: [%{text: "INFO App started", uri: "file:///logs/app.log"}]}
  ```

  ## Long example:

  ```elixir
  %ReadResourceResult{}
    |> ReadResourceResult.contents([
      %TextResourceContents{}
      |> TextResourceContents.uri("file:///logs/app.log")
      |> TextResourceContents.text("INFO App started"),
      %BlobResourceContents{}
      |> BlobResourceContents.uri("file:///assets/logo.png")
      |> BlobResourceContents.blob("iVBORw0KGgoAAAANSUhEUg==")
      |> BlobResourceContents.mime_type("image/png")
    ])
    |> ReadResourceResult._meta(%{"key" => "value"})
    |> ReadResourceResult.extras(%{"etag" => "abc123", "cached" => false})
    |> ReadResourceResult.build()
  ```

  Result:

  ```elixir
  %{
    :_meta => %{"key" => "value"},
    :contents => [
      %{text: "INFO App started", uri: "file:///logs/app.log"},
      %{
        uri: "file:///assets/logo.png",
        blob: "iVBORw0KGgoAAAANSUhEUg==",
        mimeType: "image/png"
      }
    ],
    "cached" => false,
    "etag" => "abc123"
  }
  ```

  Specification: [ReadResourceResult](https://modelcontextprotocol.io/specification/2025-11-25/schema#readresourceresult)
  """

  use OzMcp.Structs.Wire,
    fields: [
      contents: {:list, required: true, type: quote(do: [contents()])},
      _meta: :meta,
      extras: :extras
    ]

  alias OzMcp.Structs.{BlobResourceContents, ResourceContents, TextResourceContents, Validate}

  @type contents :: ResourceContents.t()

  def build(%__MODULE__{contents: contents} = struct) when is_list(contents) do
    super(%{struct | contents: build_items(contents, 0)})
  end

  def build(struct), do: super(struct)

  defp build_items([], _index), do: []

  defp build_items([%TextResourceContents{} = item | rest], index),
    do: [TextResourceContents.build(item) | build_items(rest, index + 1)]

  defp build_items([%BlobResourceContents{} = item | rest], index),
    do: [BlobResourceContents.build(item) | build_items(rest, index + 1)]

  defp build_items([%{} = item | rest], index) do
    Validate.resource_contents(item, index)
    [item | build_items(rest, index + 1)]
  end

  defp build_items([value | _], _index) do
    raise ArgumentError,
          "each content item must be a TextResourceContents, BlobResourceContents or a map, got: #{inspect(value)}"
  end

  defp build_items(value, _index), do: Validate.list(:contents, value)
end
