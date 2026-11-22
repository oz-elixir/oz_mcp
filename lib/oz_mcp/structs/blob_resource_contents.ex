defmodule OzMcp.Structs.BlobResourceContents do
  @moduledoc """
  Helper module used to build `BlobResourceContents` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %BlobResourceContents{}
    |> BlobResourceContents.uri("file:///assets/logo.png")
    |> BlobResourceContents.blob("iVBORw0KGgoAAAANSUhEUg==")
    |> BlobResourceContents.mime_type("image/png")
    |> BlobResourceContents.build()
  ```

  Result:

  ```elixir
  %{
    uri: "file:///assets/logo.png",
    blob: "iVBORw0KGgoAAAANSUhEUg==",
    mimeType: "image/png"
  }
  ```

  Specification: [BlobResourceContents](https://modelcontextprotocol.io/specification/2025-11-25/schema#blobresourcecontents)
  """

  use OzMcp.Structs.Wire,
    fields: [
      uri: {:uri, required: true, absolute: false},
      blob: {:string, required: true},
      mimeType: :string,
      _meta: :meta
    ]

  alias OzMcp.Structs.{Keys, Validate}

  @doc false
  @spec check_map(map()) :: :ok
  def check_map(item) do
    uri = Keys.get(item, "uri", :uri, "")
    Validate.non_empty_string(:uri, uri)

    Validate.non_empty_string(:blob, Keys.get(item, "blob", :blob, ""))
    Validate.non_empty_string_or_nil(:mimeType, Keys.get(item, "mimeType", :mimeType, nil))
    Validate.meta(:_meta, Keys.get(item, "_meta", :_meta, nil))
  end

  @doc false
  @spec check(t()) :: :ok
  def check(%__MODULE__{} = struct), do: check_map(Map.from_struct(struct))
end
