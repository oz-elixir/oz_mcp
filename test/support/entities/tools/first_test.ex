defmodule Support.Entities.Tools.FirstTest do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.{CallToolResult, TextContent, Tool}

  @input_schema %{
    type: "object",
    properties: %{
      location: %{
        type: "string",
        description: "City name"
      }
    },
    required: ["location"]
  }

  def list do
    list = [
      %Tool{}
      |> Tool.name("get_temperature")
      |> Tool.title("Get temperature")
      |> Tool.description("Get temperature for a location")
      |> Tool.input_schema(@input_schema)
    ]

    list
  end

  def call(_ctx, %{"name" => "get_temperature"} = params) do
    location = params["arguments"]["location"]

    result =
      %CallToolResult{}
      |> CallToolResult.content([
        %TextContent{}
        |> TextContent.text("Temperature in #{location} is 24°C")
      ])
      |> CallToolResult.build()

    {:ok, result}
  end
end
