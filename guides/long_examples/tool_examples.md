# Tool examples

Long examples of the guide [Tools](../entities/tools.md). Each example
uses the rules of that guide and this page does not repeat them.

## The DSL

This example shows each macro of the DSL. The helper
`MyApp.Fake.Tickets` stands for the ticket store of a real application:

```elixir
defmodule MyApp.Fake.Tickets do
  @moduledoc false

  # Two results, so the `{:error, reason}` clause of the tool can match.
  def count("unknown"), do: {:error, "unknown team"}
  def count(team), do: {:ok, %{"team" => team, "open" => 12, "closed" => 40}}
  def purge(_team), do: :ok
end
```

```elixir
defmodule MyApp.Tools.TeamReportTool do
  use OzMcp.Config.Tool

  alias OzMcp.{Client, Notify}
  alias OzMcp.Structs.{CallToolResult, TextContent}
  alias OzMcp.Utils.Error
  alias MyApp.Fake.Tickets

  @report_input %{
    type: "object",
    properties: %{
      team: %{type: "string", minLength: 1, description: "The name of the team"},
      weeks: %{type: "integer", minimum: 1, maximum: 52, default: 4}
    },
    required: ["team"],
    additionalProperties: false
  }

  @report_output %{
    type: "object",
    properties: %{
      team: %{type: "string"},
      open: %{type: "integer"},
      closed: %{type: "integer"}
    },
    required: ["team", "open", "closed"]
  }

  tool "team_report" do
    title "Team report"
    description "Count the open and the closed tickets of a team"
    required_scopes ["reports:read"]
    input_schema @report_input
    output_schema @report_output

    annotations do
      title "Read-only ticket report"
      read_only_hint true
      destructive_hint false
      idempotent_hint true
      open_world_hint false
    end

    execution do
      task_support "optional"
    end

    icon do
      src "https://assets.example.com/report-light.png"
      mime_type "image/png"
      sizes ["48x48"]
      theme "light"
    end

    icon do
      src "https://assets.example.com/report-dark.png"
      mime_type "image/png"
      sizes ["48x48"]
      theme "dark"
    end

    meta "owner", "engineering"
    meta :revision, "2"
  end

  tool "purge_tickets" do
    title "Purge the tickets"
    description "Delete the closed tickets of a team, after a confirmation"
    required_scopes ["admin"]

    input_schema %{
      type: "object",
      properties: %{team: %{type: "string", minLength: 1}},
      required: ["team"]
    }

    annotations do
      destructive_hint true
      idempotent_hint false
    end

    execution do
      task_support "forbidden"
    end
  end

  @impl true
  def call(ctx, %{"name" => "team_report", "arguments" => %{"team" => team}}) do
    Notify.progress(ctx, 0, total: 1, message: "Read the tickets")

    case Tickets.count(team) do
      {:ok, report} ->
        Notify.progress(ctx, 1, total: 1)

        result =
          %CallToolResult{}
          |> CallToolResult.content([
            %TextContent{}
            |> TextContent.text("#{team}: #{report["open"]} open, #{report["closed"]} closed")
          ])
          |> CallToolResult.structured_content(report)
          |> CallToolResult.build()

        {:ok, result}

      {:error, reason} ->
        {:ok,
         %CallToolResult{}
         |> CallToolResult.content([%TextContent{} |> TextContent.text(reason)])
         |> CallToolResult.is_error(true)
         |> CallToolResult.build()}
    end
  end

  def call(ctx, %{"name" => "purge_tickets", "arguments" => %{"team" => team}}) do
    schema = %{
      type: "object",
      properties: %{confirm: %{type: "boolean", title: "Delete the closed tickets?"}},
      required: ["confirm"]
    }

    case Client.elicit(ctx, schema, message: "Delete the closed tickets of #{team}?") do
      {:ok, %{action: :accept, content: %{"confirm" => true}}} ->
        :ok = Tickets.purge(team)
        {:ok, %{content: [%{type: "text", text: "The closed tickets of #{team} are deleted"}]}}

      {:ok, %{action: _declined_or_cancelled}} ->
        {:ok, %{content: [%{type: "text", text: "No change"}]}}

      {:error, :capability_not_supported} ->
        {:error, Error.invalid_params("the client cannot confirm the purge")}

      {:error, _reason} ->
        {:error, Error.internal_error("the confirmation failed")}
    end
  end
end
```

The example shows the four results of a tool callback:

  * `team_report` with a `structuredContent` that agrees with its
    `outputSchema`.
  * `team_report` with a tool error result (`isError: true`) that the
    model reads.
  * `purge_tickets` after the user confirms the call with an elicitation.
  * `purge_tickets` with a protocol error, when the client cannot run
    the elicitation.

## Way 2: data

This example shows one tool in its two forms, with the nested
values. The structs carry `required_scopes`, so the list
methods of the server filter the tools of the module:

```elixir
defmodule MyApp.Tools.DataTeamReportTool do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.{CallToolResult, Icon, TextContent, Tool, ToolAnnotations, ToolExecution}

  @impl true
  def list, do: tools()

  @impl true
  def call(_ctx, %{"name" => "team_report", "arguments" => %{"team" => team}}) do
    result =
      %CallToolResult{}
      |> CallToolResult.content([
        %TextContent{} |> TextContent.text("#{team}: 12 open, 40 closed")
      ])
      |> CallToolResult.structured_content(%{team: team, open: 12, closed: 40})
      |> CallToolResult.build()

    {:ok, result}
  end

  defp tools() do
    [
      %Tool{}
      |> Tool.name("team_report")
      |> Tool.title("Team report")
      |> Tool.description("Count the open and the closed tickets of a team")
      |> Tool.required_scopes(["reports:read"])
      |> Tool.input_schema(%{
        type: "object",
        properties: %{team: %{type: "string", minLength: 1}},
        required: ["team"]
      })
      |> Tool.output_schema(%{
        type: "object",
        properties: %{
          team: %{type: "string"},
          open: %{type: "integer"},
          closed: %{type: "integer"}
        },
        required: ["team", "open", "closed"]
      })
      |> Tool.annotations(
        %ToolAnnotations{}
        |> ToolAnnotations.title("Read-only ticket report")
        |> ToolAnnotations.read_only_hint(true)
        |> ToolAnnotations.destructive_hint(false)
        |> ToolAnnotations.idempotent_hint(true)
        |> ToolAnnotations.open_world_hint(false)
      )
      |> Tool.execution(%ToolExecution{} |> ToolExecution.task_support(:optional))
      |> Tool.icons([
        %Icon{}
        |> Icon.src("https://assets.example.com/report-light.png")
        |> Icon.mime_type("image/png")
        |> Icon.sizes(["48x48"])
        |> Icon.theme("light")
      ])
      |> Tool._meta(%{owner: "engineering", revision: "2"})
    ]
  end
end
```

The same tool as a map, with the wire keys:

```elixir
%{
  name: "team_report",
  title: "Team report",
  description: "Count the open and the closed tickets of a team",
  required_scopes: ["reports:read"],
  inputSchema: %{
    type: "object",
    properties: %{team: %{type: "string", minLength: 1}},
    required: ["team"]
  },
  outputSchema: %{
    type: "object",
    properties: %{team: %{type: "string"}, open: %{type: "integer"}, closed: %{type: "integer"}},
    required: ["team", "open", "closed"]
  },
  annotations: %{
    title: "Read-only ticket report",
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false
  },
  execution: %{taskSupport: "optional"},
  icons: [
    %{
      src: "https://assets.example.com/report-light.png",
      mimeType: "image/png",
      sizes: ["48x48"],
      theme: "light"
    }
  ],
  _meta: %{owner: "engineering", revision: "2"}
}
```
