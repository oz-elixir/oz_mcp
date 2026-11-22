#
# Test support tools whose input schema accepts a JSON null for the
# property `a`. The callback echoes the arguments it received as text,
# so a test can see the term the callback got.
#
defmodule Support.Entities.Tools.NullArgsTest do
  use OzMcp.Config.Tool, warn?: false

  alias OzMcp.Structs.{CallToolResult, TextContent}

  tool "nullable_string" do
    description "Accepts a string or a null"

    input_schema %{
      "type" => "object",
      "properties" => %{"a" => %{"type" => ["string", "null"]}}
    }
  end

  tool "null_only" do
    description "Accepts only a null"

    input_schema %{
      "type" => "object",
      "properties" => %{"a" => %{"type" => "null"}}
    }
  end

  tool "enum_null" do
    description "Accepts the string 'x' or a null"

    input_schema %{
      "type" => "object",
      "properties" => %{"a" => %{"enum" => ["x", nil]}}
    }
  end

  def call(_ctx, %{"name" => _name, "arguments" => arguments}) do
    result =
      %CallToolResult{}
      |> CallToolResult.content([
        %TextContent{} |> TextContent.text(inspect(arguments, custom_options: [sort_maps: true]))
      ])
      |> CallToolResult.build()

    {:ok, result}
  end
end
