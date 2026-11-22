defmodule OzMcp.Structs.TextResourceContents do
  @moduledoc """
  Helper module used to build `TextResourceContents` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %TextResourceContents{}
    |> TextResourceContents.uri("file:///logs/app.log")
    |> TextResourceContents.text("INFO App started")
    |> TextResourceContents.mime_type("text/plain")
    |> TextResourceContents.build()
  ```

  Result:

  ```elixir
  %{
    text: "INFO App started",
    uri: "file:///logs/app.log",
    mimeType: "text/plain"
  }
  ```

  Specification: [TextResourceContents](https://modelcontextprotocol.io/specification/2025-11-25/schema#textresourcecontents)
  """

  use OzMcp.Structs.Wire,
    fields: [
      uri: {:uri, required: true, absolute: false},
      text: {:string, required: true},
      mimeType: :string,
      _meta: :meta
    ]

  alias OzMcp.Structs.{Keys, Validate}

  @doc false
  @spec check_map(map()) :: :ok
  def check_map(item) do
    uri = Keys.get(item, "uri", :uri, "")
    Validate.non_empty_string(:uri, uri)

    Validate.non_empty_string(:text, Keys.get(item, "text", :text, ""))
    Validate.non_empty_string_or_nil(:mimeType, Keys.get(item, "mimeType", :mimeType, nil))
    Validate.meta(:_meta, Keys.get(item, "_meta", :_meta, nil))
  end

  @doc false
  @spec check(t()) :: :ok
  def check(%__MODULE__{} = struct), do: check_map(Map.from_struct(struct))
end
