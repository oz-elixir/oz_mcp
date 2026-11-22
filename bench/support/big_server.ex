# The tool-heavy server of the benchmark: 200 tools, 50 prompts, 50
# resources and 50 templates, all declared with the DSL, plus the
# result-heavy modules. The last entity of each DSL kind keeps its place
# as the entity that the request scenarios of the DSL path address.
#

for index <- 1..10 do
  #
  # A tool module of 20 tools declared with the DSL, with an input and an
  # output schema: the callback echoes the text of the arguments.
  #
  defmodule Module.concat([Bench.BigServer.Tools, "T#{index}"]) do
    use OzMcp.Config.Tool, warn?: false

    alias OzMcp.Structs.{CallToolResult, TextContent}

    @input_schema %{
      type: "object",
      properties: %{
        text: %{type: "string"},
        count: %{type: "integer"},
        flag: %{type: "boolean"}
      }
    }

    @output_schema %{
      type: "object",
      properties: %{result: %{type: "string"}},
      required: ["result"]
    }

    for n <- 1..20 do
      tool "tool_#{index}_#{n}" do
        title "Benchmark tool #{index}.#{n}"
        description "Echoes the text of the arguments"
        input_schema @input_schema
        output_schema @output_schema
      end
    end

    @impl true
    def call(_ctx, params) do
      text = get_in(params, ["arguments", "text"]) || ""

      result =
        %CallToolResult{}
        |> CallToolResult.content([%TextContent{} |> TextContent.text(text)])
        |> CallToolResult.structured_content(%{result: text})
        |> CallToolResult.build()

      {:ok, result}
    end
  end
end

for index <- 1..5 do
  #
  # A prompt module of 10 prompts declared with the DSL.
  #
  defmodule Module.concat([Bench.BigServer.Prompts, "P#{index}"]) do
    use OzMcp.Config.Prompt, warn?: false

    for n <- 1..10 do
      prompt "prompt_#{index}_#{n}" do
        title "Benchmark prompt #{index}.#{n}"
        description "A benchmark prompt"
        argument "text", required: true, description: "The text"
      end
    end

    @impl true
    def get(_ctx, _params), do: {:ok, %{messages: []}}
  end
end

for index <- 1..5 do
  #
  # A resource module of 10 resources declared with the DSL.
  #
  defmodule Module.concat([Bench.BigServer.Resources, "R#{index}"]) do
    use OzMcp.Config.Resource, warn?: false

    for n <- 1..10 do
      resource "resource_#{index}_#{n}.md" do
        uri "bench-res-#{index}://items/#{n}.md"
        title "Benchmark resource #{index}.#{n}"
        description "A benchmark resource"
        mime_type "text/markdown"
      end
    end

    @impl true
    def read(_ctx, params) do
      {:ok, %{contents: [%{uri: params["uri"], text: "bench"}]}}
    end
  end
end

for index <- 1..5 do
  #
  # A template module of 10 templates declared with the DSL, one URI
  # scheme for each module.
  #
  defmodule Module.concat([Bench.BigServer.Templates, "T#{index}"]) do
    use OzMcp.Config.Template, warn?: false

    for n <- 1..10 do
      template "Template #{index}.#{n}" do
        uri_template "bench-tpl-#{index}://items/#{n}/{id}"
        title "Benchmark template #{index}.#{n}"
        description "A benchmark template"
        mime_type "text/markdown"
      end
    end

    @impl true
    def read(_ctx, params, _uri_template, _uri_params) do
      {:ok, %{contents: [%{uri: params["uri"], text: "bench"}]}}
    end
  end
end

#
# The result-heavy tool: its callback returns a map with 50 blocks, so
# each request pays the check of a big result.
#
defmodule Bench.BigServer.ManyBlocks do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.Tool

  @tool %Tool{}
        |> Tool.name("tool_50_blocks")
        |> Tool.description("Returns a map with 50 blocks")

  @blocks for _ <- 1..50, do: %{type: "text", text: "bench", annotations: %{priority: 0.5}}

  def list do
    [@tool]
  end

  def call(_ctx, _params), do: {:ok, %{content: @blocks}}
end

#
# The result-heavy resource: its callback returns a map with 50 items,
# so each request pays the check of a big result.
#
defmodule Bench.BigServer.ManyItems do
  use OzMcp.Config.Resource, dsl?: false

  @resource %{
    uri: "bench-res-many://items",
    name: "many_items.md",
    description: "Returns a map with 50 items",
    mimeType: "text/markdown"
  }

  @items for n <- 1..50, do: %{uri: "bench-res-many://items/#{n}", text: "bench"}

  def list do
    [@resource]
  end

  def read(_ctx, _params), do: {:ok, %{contents: @items}}
end

#
# The tool-heavy server of the benchmark: 10 tool modules of 20 tools, one
# tool module whose callback returns a map with 50 blocks, 5 prompt modules
# of 10 prompts, 5 resource modules of 10 resources, one resource module
# whose callback returns a map with 50 items and 5 template modules of 10
# templates, one URI scheme for each template module.
#
defmodule Bench.BigServer do
  use OzMcp.Config.Server

  @last_tool_name "tool_10_20"
  @last_template_uri "bench-tpl-5://items/10/1"
  @many_blocks_tool "tool_50_blocks"
  @many_items_uri "bench-res-many://items"

  server_info do
    name "bench-big-server"
    version "1.0.0"
  end

  tools do
    tool Bench.BigServer.Tools.T1
    tool Bench.BigServer.Tools.T2
    tool Bench.BigServer.Tools.T3
    tool Bench.BigServer.Tools.T4
    tool Bench.BigServer.Tools.T5
    tool Bench.BigServer.Tools.T6
    tool Bench.BigServer.Tools.T7
    tool Bench.BigServer.Tools.T8
    tool Bench.BigServer.Tools.T9
    tool Bench.BigServer.Tools.T10
    tool Bench.BigServer.ManyBlocks
  end

  prompts do
    prompt Bench.BigServer.Prompts.P1
    prompt Bench.BigServer.Prompts.P2
    prompt Bench.BigServer.Prompts.P3
    prompt Bench.BigServer.Prompts.P4
    prompt Bench.BigServer.Prompts.P5
  end

  resources do
    resource Bench.BigServer.Resources.R1
    resource Bench.BigServer.Resources.R2
    resource Bench.BigServer.Resources.R3
    resource Bench.BigServer.Resources.R4
    resource Bench.BigServer.Resources.R5
    resource Bench.BigServer.ManyItems
  end

  templates do
    template Bench.BigServer.Templates.T1
    template Bench.BigServer.Templates.T2
    template Bench.BigServer.Templates.T3
    template Bench.BigServer.Templates.T4
    template Bench.BigServer.Templates.T5
  end

  # The name of the last tool of the last module.
  #
  @spec last_tool_name() :: String.t()
  def last_tool_name, do: @last_tool_name

  # A URI that matches the last template of the last module.
  #
  @spec last_template_uri() :: String.t()
  def last_template_uri, do: @last_template_uri

  # The name of the tool whose callback returns a map with 50 blocks.
  #
  @spec many_blocks_tool() :: String.t()
  def many_blocks_tool, do: @many_blocks_tool

  # The URI of the resource whose callback returns a map with 50 items.
  #
  @spec many_items_uri() :: String.t()
  def many_items_uri, do: @many_items_uri
end
