defmodule OzMcp.Structs.InitializeResult do
  @moduledoc """
  Helper module used to build `InitializeResult` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %InitializeResult{}
    |> InitializeResult.protocol_version("2025-11-25")
    |> InitializeResult.server_info(
      %Implementation{}
      |> Implementation.name("my-server")
      |> Implementation.version("1.0.0")
    )
    |> InitializeResult.build()
  ```

  Result:

  ```elixir
  %{
    capabilities: %{},
    protocolVersion: "2025-11-25",
    serverInfo: %{name: "my-server", version: "1.0.0"}
  }
  ```

  ## Long example:

  ```elixir
  %InitializeResult{}
    |> InitializeResult.protocol_version("2025-11-25")
    |> InitializeResult.capabilities(
      %ServerCapabilities{}
      |> ServerCapabilities.tools(true)
    )
    |> InitializeResult.server_info(
      %Implementation{}
      |> Implementation.name("my-server")
      |> Implementation.title("My MCP Server")
      |> Implementation.version("1.0.0")
    )
    |> InitializeResult.instructions("Use the tools responsibly")
    |> InitializeResult.extras(%{"region" => "eu-west-1", "release" => "stable"})
    |> InitializeResult.build()
  ```

  Result:

  ```elixir
  %{
    :instructions => "Use the tools responsibly",
    :capabilities => %{tools: %{}},
    :protocolVersion => "2025-11-25",
    :serverInfo => %{
      name: "my-server",
      version: "1.0.0",
      title: "My MCP Server"
    },
    "region" => "eu-west-1",
    "release" => "stable"
  }
  ```

  Specification: [InitializeResult](https://modelcontextprotocol.io/specification/2025-11-25/schema#initializeresult)
  """

  use OzMcp.Structs.Wire,
    fields: [
      protocolVersion: {:string, required: true},
      instructions: :string,
      _meta: :meta,
      extras: :extras,
      capabilities:
        {{:struct, OzMcp.Structs.ServerCapabilities},
         required: true, default: %OzMcp.Structs.ServerCapabilities{}},
      serverInfo:
        {{:struct, OzMcp.Structs.Implementation},
         required: true, default: %OzMcp.Structs.Implementation{}}
    ]
end
