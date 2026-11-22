defmodule OzMcp.Structs.Prompt do
  @moduledoc """
  Helper module used to build `Prompt` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %Prompt{}
    |> Prompt.name("get_weather")
    |> Prompt.description("Get the weather for a city")
    |> Prompt.build()
  ```

  Result:

  ```elixir
  %{name: "get_weather", description: "Get the weather for a city"}
  ```

  ## Long example:

  ```elixir
  %Prompt{}
    |> Prompt.name("get_weather")
    |> Prompt.title("Get the weather")
    |> Prompt.description("Get the weather for a city")
    |> Prompt.arguments([
      %PromptArgument{}
      |> PromptArgument.name("city")
      |> PromptArgument.description("The city name")
      |> PromptArgument.required(true)
    ])
    |> Prompt.icons([
      %Icon{}
      |> Icon.src("https://img.com/icon.png")
      |> Icon.mime_type("image/png")
      |> Icon.sizes(["16x16"])
    ])
    |> Prompt.build()
  ```

  Result:

  ```elixir
  %{
    name: "get_weather",
    description: "Get the weather for a city",
    title: "Get the weather",
    arguments: [%{name: "city", description: "The city name", required: true}],
    icons: [
      %{
        src: "https://img.com/icon.png",
        sizes: ["16x16"],
        mimeType: "image/png"
      }
    ]
  }
  ```

  The `required_scopes` field holds the scopes that a principal must hold to
  use the prompt. OzMcp uses them for the check of `prompts/get` and for the
  filter of `prompts/list`. They are never sent to the client.

  Specification: [Prompt](https://modelcontextprotocol.io/specification/2025-11-25/schema#prompt)
  """

  use OzMcp.Structs.Wire,
    fields: [
      name: {:string, required: true},
      title: :string,
      description: :string,
      arguments: {:list_of, OzMcp.Structs.PromptArgument},
      _meta: :meta,
      icons: {:list_of, OzMcp.Structs.Icon},
      required_scopes: :scopes,
      extras: :extras
    ]
end
