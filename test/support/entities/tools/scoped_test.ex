#
# Tools with and without `required_scopes`. The name of the tool that ran
# is kept in :persistent_term, so the tests can pin whether a callback
# ran (the framework runs a callback in its own process).
#
defmodule Support.Entities.Tools.ScopedTest do
  use OzMcp.Config.Tool, warn?: false

  alias OzMcp.Structs.{CallToolResult, TextContent}

  tool "read_file" do
    title "Read a file"
    description "Read a file from the store"

    input_schema %{
      type: "object",
      properties: %{path: %{type: "string"}},
      required: ["path"]
    }
  end

  tool "write_file" do
    title "Write a file"
    description "Write a file to the store"
    required_scopes(["files:write"])

    input_schema %{
      type: "object",
      properties: %{path: %{type: "string"}},
      required: ["path"]
    }

    execution do
      task_support "optional"
    end
  end

  tool "admin_tool" do
    title "Admin"
    description "An administrative tool"
    required_scopes(["files:write", "admin"])

    input_schema %{
      type: "object",
      properties: %{}
    }
  end

  def call(_ctx, %{"name" => name} = _params) do
    :persistent_term.put({__MODULE__, :ran}, name)

    result =
      %CallToolResult{}
      |> CallToolResult.content([
        %TextContent{}
        |> TextContent.text("#{name} ran")
      ])
      |> CallToolResult.build()

    {:ok, result}
  end

  def reset, do: :persistent_term.put({__MODULE__, :ran}, nil)

  def last_ran, do: :persistent_term.get({__MODULE__, :ran}, nil)
end
