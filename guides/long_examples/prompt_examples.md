# Prompt examples

Long examples of the guide [Prompts](../entities/prompts.md). Each
example uses the rules of that guide and this page does not repeat them.

## The DSL

This example shows each macro of the DSL, two prompts in one
module and the optional `complete/4` callback for one argument:

```elixir
defmodule MyApp.Prompts.EngineeringPrompt do
  use OzMcp.Config.Prompt

  alias OzMcp.Structs.{
    CompleteResult,
    Completion,
    EmbeddedResource,
    GetPromptResult,
    PromptMessage,
    TextContent,
    TextResourceContents
  }

  @languages ["elixir", "erlang", "gleam", "javascript", "python"]

  prompt "code_review" do
    title "Code review"
    description "Review a piece of code and report the defects"
    required_scopes ["reviews:run"]

    argument "language",
      title: "Language",
      description: "The programming language of the code",
      required: true

    argument "focus", title: "Focus", description: "security, speed or style"

    icon do
      src "https://assets.example.com/review-light.svg"
      mime_type "image/svg+xml"
      sizes ["any"]
      theme "light"
    end

    icon do
      src "https://assets.example.com/review-dark.svg"
      mime_type "image/svg+xml"
      sizes ["any"]
      theme "dark"
    end

    meta "version", "1.0"
    meta :owner, "engineering"
  end

  prompt "definitions" do
    title "Project definitions"
    description "Explain the definitions list of the project"
  end

  @impl true
  def get(_ctx, %{"name" => "code_review", "arguments" => args}) do
    language = args["language"]
    focus = Map.get(args, "focus", "all the defects")

    result =
      %GetPromptResult{}
      |> GetPromptResult.description("Code review in #{language}")
      |> GetPromptResult.messages([
        %PromptMessage{}
        |> PromptMessage.role(:user)
        |> PromptMessage.content(
          %TextContent{}
          |> TextContent.text("Review the #{language} code below. Report #{focus}.")
        ),
        %PromptMessage{}
        |> PromptMessage.role(:assistant)
        |> PromptMessage.content(
          %TextContent{}
          |> TextContent.text("Send the code. I will list each defect with its line.")
        )
      ])
      |> GetPromptResult.build()

    {:ok, result}
  end

  def get(_ctx, %{"name" => "definitions"}) do
    result =
      %GetPromptResult{}
      |> GetPromptResult.messages([
        %PromptMessage{}
        |> PromptMessage.role(:user)
        |> PromptMessage.content(
          %EmbeddedResource{}
          |> EmbeddedResource.resource(
            %TextResourceContents{}
            |> TextResourceContents.uri("file:///definitions.md")
            |> TextResourceContents.mime_type("text/markdown")
            |> TextResourceContents.text("# Definitions")
          )
        )
      ])
      |> GetPromptResult.build()

    {:ok, result}
  end

  @impl true
  def complete(_ctx, "code_review", %{"name" => "language", "value" => prefix}, _context) do
    values = Enum.filter(@languages, &String.starts_with?(&1, prefix))

    {:ok,
     %CompleteResult{}
     |> CompleteResult.completion(%Completion{} |> Completion.values(values))
     |> CompleteResult.build()}
  end

  def complete(_ctx, _name, _argument, _context), do: {:ok, %{completion: %{values: []}}}
end
```

Each `get/2` clause matches on the name of the prompt. The clause that
matches gives the messages of that prompt. The messages of
`code_review` hold one user message and one assistant message. The
messages of `definitions` hold an embedded resource: the client reads
the contents of the resource from the message.

The first clause of `complete/4` matches the argument `language`. Each
other reference gets the second clause with an empty list of values.
The guide about completions gives the details of the `complete/4`
callback.

`required_scopes ["reviews:run"]` protects the prompt. A `prompts/get`
without all the scopes gets the status `403` and `prompts/list` hides
the prompt from a principal that lacks them. The guide about
authorization gives the details.

## Way 2: data

This example shows one prompt in the two forms, with the nested
values. The structs carry `required_scopes`, so the list
methods of the server filter the list of the module:

```elixir
defmodule MyApp.Prompts.DataEngineeringPrompt do
  use OzMcp.Config.Prompt, dsl?: false

  alias OzMcp.Structs.{GetPromptResult, Icon, Prompt, PromptArgument, PromptMessage, TextContent}

  @impl true
  def list, do: prompts()

  @impl true
  def get(_ctx, %{"name" => "code_review", "arguments" => %{"language" => language}}) do
    {:ok,
     %GetPromptResult{}
     |> GetPromptResult.description("Code review in #{language}")
     |> GetPromptResult.messages([
       %PromptMessage{}
       |> PromptMessage.role(:user)
       |> PromptMessage.content(%TextContent{} |> TextContent.text("Review the #{language} code below."))
     ])
     |> GetPromptResult.build()}
  end

  defp prompts() do
    [
      %Prompt{}
      |> Prompt.name("code_review")
      |> Prompt.title("Code review")
      |> Prompt.description("Review a piece of code and report the defects")
      |> Prompt.required_scopes(["reviews:run"])
      |> Prompt.arguments([
        %PromptArgument{}
        |> PromptArgument.name("language")
        |> PromptArgument.title("Language")
        |> PromptArgument.description("The programming language")
        |> PromptArgument.required(true),
        %PromptArgument{}
        |> PromptArgument.name("focus")
        |> PromptArgument.description("security, speed or style")
      ])
      |> Prompt.icons([
        %Icon{}
        |> Icon.src("https://assets.example.com/review-light.svg")
        |> Icon.mime_type("image/svg+xml")
        |> Icon.theme("light")
      ])
      |> Prompt._meta(%{version: "1.0"})
    ]
  end
end
```

The same prompt as a map with the wire keys:

```elixir
%{
  name: "code_review",
  title: "Code review",
  description: "Review a piece of code and report the defects",
  required_scopes: ["reviews:run"],
  arguments: [
    %{name: "language", title: "Language", description: "The programming language", required: true},
    %{name: "focus", title: "Focus", description: "security, speed or style"}
  ],
  icons: [
    %{src: "https://assets.example.com/review-light.svg", mimeType: "image/svg+xml", theme: "light"}
  ],
  _meta: %{version: "1.0"}
}
```
