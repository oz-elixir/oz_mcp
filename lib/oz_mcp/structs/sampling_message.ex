defmodule OzMcp.Structs.SamplingMessage do
  @moduledoc """
  Helper module used to build `SamplingMessage` structure: a message of the
  conversation the server asks the client to complete.

  _(MCP protocol: 2025-11-25)_

  `content` is one block or a list of blocks. A block is a `TextContent`,
  `ImageContent`, `AudioContent`, `ToolUseContent` or `ToolResultContent`
  struct, or a map that is already a block.

  ## Short example:

  ```elixir
  %SamplingMessage{}
    |> SamplingMessage.role(:user)
    |> SamplingMessage.content(%TextContent{} |> TextContent.text("Hello"))
    |> SamplingMessage.build()
  ```

  Result:

  ```elixir
  %{role: "user", content: %{type: "text", text: "Hello"}}
  ```

  `user/1` and `assistant/1` build a message from a text:

  ```elixir
  SamplingMessage.user("Hello") |> SamplingMessage.build()
  ```

  Specification: [SamplingMessage](https://modelcontextprotocol.io/specification/2025-11-25/schema#samplingmessage)
  """

  use OzMcp.Structs.Wire,
    build: false,
    fields: [
      role: {:any, default: :user, type: quote(do: role() | String.t())},
      content: {:any, type: quote(do: block() | list(block()) | nil)},
      _meta: :meta
    ]

  alias OzMcp.Structs.{
    AudioContent,
    Builder,
    ImageContent,
    TextContent,
    ToolResultContent,
    ToolUseContent,
    Validate
  }

  @type role :: :user | :assistant

  @type block ::
          %TextContent{}
          | %ImageContent{}
          | %AudioContent{}
          | %ToolUseContent{}
          | %ToolResultContent{}
          | map()

  @doc """
  A `user` message with a text content.
  """
  @spec user(String.t()) :: %__MODULE__{}
  def user(text), do: text_message(:user, text)

  @doc """
  An `assistant` message with a text content.
  """
  @spec assistant(String.t()) :: %__MODULE__{}
  def assistant(text), do: text_message(:assistant, text)

  @spec build(t()) :: map()
  def build(struct) do
    Validate.one_of(:role, struct.role, Validate.roles())
    Validate.meta(:_meta, struct._meta)

    %{role: to_string(struct.role), content: content_of(struct.content)}
    |> Builder.maybe_meta(struct)
  end

  defp text_message(role, text) do
    %__MODULE__{role: role, content: %TextContent{} |> TextContent.text(text)}
  end

  defp content_of([_ | _] = blocks), do: Enum.map(blocks, &block/1)

  defp content_of([]) do
    raise ArgumentError, "The 'content' field cannot be an empty list"
  end

  defp content_of(nil) do
    raise ArgumentError, "The 'content' field is required"
  end

  defp content_of(block), do: block(block)

  defp block(%TextContent{} = c), do: TextContent.build(c)
  defp block(%ImageContent{} = c), do: ImageContent.build(c)
  defp block(%AudioContent{} = c), do: AudioContent.build(c)
  defp block(%ToolUseContent{} = c), do: ToolUseContent.build(c)
  defp block(%ToolResultContent{} = c), do: ToolResultContent.build(c)
  defp block(%{} = c) when not is_struct(c), do: c

  defp block(other) do
    raise ArgumentError,
          "a content block must be a TextContent, ImageContent, AudioContent, " <>
            "ToolUseContent or ToolResultContent struct or a map, got: #{inspect(other)}"
  end
end
