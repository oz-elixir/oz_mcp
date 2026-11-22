defmodule OzMcp.Structs.GetPromptResult do
  @moduledoc """
  Helper module used to build `GetPromptResult` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %GetPromptResult{}
    |> GetPromptResult.messages([
      %PromptMessage{}
      |> PromptMessage.role(:user)
      |> PromptMessage.content(
        %TextContent{}
        |> TextContent.text("Hello, world!")
      )
    ])
    |> GetPromptResult.build()
  ```

  Result:

  ```elixir
  %{
    messages: [
      %{"content" => %{type: "text", text: "Hello, world!"}, "role" => "user"}
    ]
  }
  ```

  ## Long example:

  ```elixir
  %GetPromptResult{}
    |> GetPromptResult.description("Get the weather for a city")
    |> GetPromptResult.messages([
      %PromptMessage{}
      |> PromptMessage.role(:user)
      |> PromptMessage.content(
        %TextContent{}
        |> TextContent.text("What is the weather in Paris?")
      ),
      %PromptMessage{}
      |> PromptMessage.role(:assistant)
      |> PromptMessage.content(
        %TextContent{}
        |> TextContent.text("The weather in Paris is sunny.")
      )
    ])
    |> GetPromptResult.build()
  ```

  Result:

  ```elixir
  %{
    messages: [
      %{
        "content" => %{type: "text", text: "What is the weather in Paris?"},
        "role" => "user"
      },
      %{
        "content" => %{type: "text", text: "The weather in Paris is sunny."},
        "role" => "assistant"
      }
    ],
    description: "Get the weather for a city"
  }
  ```

  Specification: [GetPromptResult](https://modelcontextprotocol.io/specification/2025-11-25/schema#getpromptresult)
  """

  use OzMcp.Structs.Wire,
    fields: [
      messages:
        {{:maps_of, OzMcp.Structs.PromptMessage}, required: true, type: quote(do: messages())},
      description: :string,
      _meta: :meta
    ]

  alias OzMcp.Structs.{PromptMessage, Validate}

  @type messages :: OzMcp.Structs.Types.list_of(%OzMcp.Structs.PromptMessage{})

  def build(%__MODULE__{messages: messages} = struct) when is_list(messages) do
    Validate.list(:messages, messages)
    Enum.each(messages, &PromptMessage.check/1)
    super(struct)
  end

  def build(struct), do: super(struct)
end
