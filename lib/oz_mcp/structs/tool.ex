defmodule OzMcp.Structs.Tool do
  @moduledoc """
  Helper module used to build `Tool` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %Tool{}
    |> Tool.name("get_date")
    |> Tool.title("Get the current date (new)")
    |> Tool.description("Get the current date formatted as %d/%m/%Y")
    |> Tool.build()
  ```

  Result:

  ```elixir
  %{
    name: "get_date",
    description: "Get the current date formatted as %d/%m/%Y",
    title: "Get the current date (new)",
    inputSchema: %{type: "object", properties: %{}}
  }
  ```

  ## Long example:

  ```elixir
  %Tool{}
    |> Tool.name("get_date")
    |> Tool.title("Get the current date")
    |> Tool.description("Get the current date formatted as %d/%m/%Y")
    |> Tool.execution(
      %ToolExecution{}
      |> ToolExecution.task_support(:forbidden)
    )
    |> Tool.icons([
      %Icon{}
      |> Icon.src("https://img.com/icon.png")
      |> Icon.mime_type("image/png")
      |> Icon.sizes(["16x16"])
    ])
    |> Tool._meta(%{
      id: "472",
      md5: "154173f63ed5380419b649e66173e148"
    })
    |> Tool.build()
  ```

  Result:

  ```elixir
  %{
    name: "get_date",
    description: "Get the current date formatted as %d/%m/%Y",
    title: "Get the current date",
    execution: %{taskSupport: :forbidden},
    icons: [
      %{
        src: "https://img.com/icon.png",
        sizes: ["16x16"],
        mimeType: "image/png"
      }
    ],
    _meta: %{id: "472", md5: "154173f63ed5380419b649e66173e148"},
    inputSchema: %{type: "object", properties: %{}}
  }
  ```

  The `required_scopes` field holds the scopes that a principal must hold to
  use the tool. OzMcp uses them for the check of `tools/call` and for the
  filter of `tools/list`. They are never sent to the client.

  Specification: [Tool](https://modelcontextprotocol.io/specification/2025-11-25/schema#tool)
  """

  use OzMcp.Structs.Wire,
    fields: [
      name: {:string, required: true},
      title: :string,
      description: :string,
      inputSchema: {:map, required: true, check: :validate_input},
      outputSchema: {:map, check: :validate_output},
      _meta: :meta,
      icons: {:list_of, OzMcp.Structs.Icon},
      execution: {:struct, OzMcp.Structs.ToolExecution},
      annotations: {:struct, OzMcp.Structs.ToolAnnotations},
      required_scopes: :scopes,
      extras: :extras
    ]

  def build(struct) do
    case super(struct) do
      %{inputSchema: schema} = result when map_size(schema) == 0 ->
        %{result | inputSchema: %{type: "object", properties: %{}}}

      result ->
        result
    end
  end

  defp validate_input(value), do: OzMcp.Structs.Validate.input_schema(value)

  defp validate_output(value), do: OzMcp.Structs.Validate.output_schema_or_nil(value)
end
