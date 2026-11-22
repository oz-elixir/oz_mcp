#
# The tools that the server scenarios of `@modelcontextprotocol/conformance`
# call by name.
#
defmodule OzMcp.E2E.ConformanceServer.Tools do
  use OzMcp.Config.Tool

  alias OzMcp.{Client, Notify}
  alias OzMcp.Structs.{CallToolResult, SamplingMessage, TextContent}

  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
  @wav "UklGRiQAAABXQVZFZm10IBAAAAABAAEAESsAABErAAABAAgAZGF0YQAAAAA="

  tool "test_simple_text" do
    title "Simple text"
    description "Returns a simple text content"
  end

  tool "test_image_content" do
    title "Image content"
    description "Returns an image content"
  end

  tool "test_audio_content" do
    title "Audio content"
    description "Returns an audio content"
  end

  tool "test_embedded_resource" do
    title "Embedded resource"
    description "Returns an embedded resource content"
  end

  tool "test_multiple_content_types" do
    title "Multiple content types"
    description "Returns a text, an image and an embedded resource"
  end

  tool "test_tool_with_logging" do
    title "Tool with logging"
    description "Sends three log messages while it runs"
  end

  tool "test_tool_with_progress" do
    title "Tool with progress"
    description "Reports three progress notifications while it runs"
  end

  tool "test_error_handling" do
    title "Error handling"
    description "Always returns a tool error"
  end

  tool "test_sampling" do
    title "Sampling"
    description "Asks the client for a sampling of the prompt"

    input_schema %{
      type: "object",
      properties: %{prompt: %{type: "string"}},
      required: ["prompt"]
    }
  end

  tool "test_elicitation" do
    title "Elicitation"
    description "Asks the user for a username and an email"

    input_schema %{
      type: "object",
      properties: %{message: %{type: "string"}},
      required: ["message"]
    }
  end

  tool "test_elicitation_sep1034_defaults" do
    title "Elicitation defaults"
    description "Asks the user with a default value for each primitive type"
  end

  tool "test_elicitation_sep1330_enums" do
    title "Elicitation enums"
    description "Asks the user with the five enum variants"
  end

  @impl true
  def call(_ctx, %{"name" => "test_simple_text"}),
    do: {:ok, content([text("This is a simple text response for testing.")])}

  def call(_ctx, %{"name" => "test_image_content"}),
    do: {:ok, content([%{type: "image", data: @png, mimeType: "image/png"}])}

  def call(_ctx, %{"name" => "test_audio_content"}),
    do: {:ok, content([%{type: "audio", data: @wav, mimeType: "audio/wav"}])}

  def call(_ctx, %{"name" => "test_embedded_resource"}) do
    resource = %{
      uri: "test://embedded-resource",
      mimeType: "text/plain",
      text: "This is an embedded resource content."
    }

    {:ok, content([%{type: "resource", resource: resource}])}
  end

  def call(_ctx, %{"name" => "test_multiple_content_types"}) do
    resource = %{
      uri: "test://mixed-content-resource",
      mimeType: "application/json",
      text: ~s({"test":"data","value":123})
    }

    {:ok,
     content([
       text("Multiple content types test:"),
       %{type: "image", data: @png, mimeType: "image/png"},
       %{type: "resource", resource: resource}
     ])}
  end

  def call(ctx, %{"name" => "test_tool_with_logging"}) do
    :ok = Notify.log(ctx, :info, "Tool execution started")
    :ok = Notify.log(ctx, :info, "Tool processing data")
    :ok = Notify.log(ctx, :info, "Tool execution completed")
    {:ok, content([text("Tool execution completed with logging")])}
  end

  def call(ctx, %{"name" => "test_tool_with_progress"}) do
    :ok = Notify.progress(ctx, 0, total: 100)
    :ok = Notify.progress(ctx, 50, total: 100)
    :ok = Notify.progress(ctx, 100, total: 100)
    {:ok, content([text("Tool execution completed with progress")])}
  end

  def call(_ctx, %{"name" => "test_error_handling"}) do
    {:ok,
     %CallToolResult{}
     |> CallToolResult.content([
       %TextContent{} |> TextContent.text("This tool intentionally returns an error for testing")
     ])
     |> CallToolResult.is_error(true)
     |> CallToolResult.build()}
  end

  def call(ctx, %{"name" => "test_sampling", "arguments" => %{"prompt" => prompt}}) do
    case Client.sample(ctx, [SamplingMessage.user(prompt)], max_tokens: 100) do
      {:ok, %{content: %{"text" => answer}}} ->
        {:ok, content([text("LLM response: #{answer}")])}

      {:ok, other} ->
        {:ok, content([text("LLM response: #{inspect(other)}")])}

      {:error, reason} ->
        {:error, OzMcp.Utils.Error.new(-32603, "sampling failed: #{inspect(reason)}")}
    end
  end

  def call(ctx, %{"name" => "test_elicitation", "arguments" => %{"message" => message}}) do
    schema = %{
      type: "object",
      properties: %{
        username: %{type: "string", description: "User's response"},
        email: %{type: "string", description: "User's email address"}
      },
      required: ["username", "email"]
    }

    answer(ctx, schema, message, "User response")
  end

  def call(ctx, %{"name" => "test_elicitation_sep1034_defaults"}) do
    schema = %{
      type: "object",
      properties: %{
        name: %{type: "string", default: "John Doe"},
        age: %{type: "integer", default: 30},
        score: %{type: "number", default: 95.5},
        status: %{type: "string", enum: ["active", "inactive", "pending"], default: "active"},
        verified: %{type: "boolean", default: true}
      }
    }

    answer(ctx, schema, "Provide your details", "Elicitation completed")
  end

  def call(ctx, %{"name" => "test_elicitation_sep1330_enums"}) do
    schema = %{
      type: "object",
      properties: %{
        untitledSingle: %{type: "string", enum: ["option1", "option2", "option3"]},
        titledSingle: %{
          type: "string",
          oneOf: [
            %{const: "value1", title: "First Option"},
            %{const: "value2", title: "Second Option"},
            %{const: "value3", title: "Third Option"}
          ]
        },
        legacyEnum: %{
          type: "string",
          enum: ["opt1", "opt2", "opt3"],
          enumNames: ["Option One", "Option Two", "Option Three"]
        },
        untitledMulti: %{
          type: "array",
          items: %{type: "string", enum: ["option1", "option2", "option3"]}
        },
        titledMulti: %{
          type: "array",
          items: %{
            anyOf: [
              %{const: "value1", title: "First Choice"},
              %{const: "value2", title: "Second Choice"},
              %{const: "value3", title: "Third Choice"}
            ]
          }
        }
      }
    }

    answer(ctx, schema, "Choose your options", "Elicitation completed")
  end

  defp answer(ctx, schema, message, label) do
    case Client.elicit(ctx, schema, message: message) do
      {:ok, %{action: action} = result} ->
        summary = "#{label}: action=#{action}, content=#{inspect(Map.get(result, :content))}"
        {:ok, content([text(summary)])}

      {:error, reason} ->
        {:error, OzMcp.Utils.Error.new(-32603, "elicitation failed: #{inspect(reason)}")}
    end
  end

  defp text(text), do: %{type: "text", text: text}

  defp content(items), do: %{content: items}
end

defmodule OzMcp.E2E.ConformanceServer.Prompts do
  use OzMcp.Config.Prompt

  alias OzMcp.Structs.{CompleteResult, Completion}

  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

  prompt "test_simple_prompt" do
    title "Simple prompt"
    description "A prompt with no argument"
  end

  prompt "test_prompt_with_arguments" do
    title "Prompt with arguments"
    description "A prompt with two required arguments"
    argument "arg1", description: "First test argument", required: true
    argument "arg2", description: "Second test argument", required: true
  end

  prompt "test_prompt_with_embedded_resource" do
    title "Prompt with an embedded resource"
    description "A prompt that embeds the resource of its argument"
    argument "resourceUri", description: "URI of the resource to embed", required: true
  end

  prompt "test_prompt_with_image" do
    title "Prompt with an image"
    description "A prompt with an image content"
  end

  @impl true
  def get(_ctx, %{"name" => "test_simple_prompt"}),
    do: {:ok, messages([user_text("This is a simple prompt for testing.")])}

  def get(_ctx, %{"name" => "test_prompt_with_arguments", "arguments" => args}) do
    text = "Prompt with arguments: arg1='#{args["arg1"]}', arg2='#{args["arg2"]}'"
    {:ok, messages([user_text(text)])}
  end

  def get(_ctx, %{"name" => "test_prompt_with_embedded_resource", "arguments" => args}) do
    resource = %{
      uri: args["resourceUri"],
      mimeType: "text/plain",
      text: "Embedded resource content for testing."
    }

    {:ok,
     messages([
       %{role: "user", content: %{type: "resource", resource: resource}},
       user_text("Please process the embedded resource above.")
     ])}
  end

  def get(_ctx, %{"name" => "test_prompt_with_image"}) do
    {:ok,
     messages([
       %{role: "user", content: %{type: "image", data: @png, mimeType: "image/png"}},
       user_text("Please analyze the image above.")
     ])}
  end

  @impl true
  def complete(_ctx, "test_prompt_with_arguments", %{"name" => "arg1", "value" => value}, _ctx2) do
    values = Enum.filter(["paris", "park", "party"], &String.starts_with?(&1, value))

    {:ok,
     %CompleteResult{}
     |> CompleteResult.completion(%Completion{} |> Completion.values(values))
     |> CompleteResult.build()}
  end

  def complete(_ctx, _name, _argument, _context) do
    {:ok,
     %CompleteResult{}
     |> CompleteResult.completion(%Completion{} |> Completion.values([]))
     |> CompleteResult.build()}
  end

  defp user_text(text), do: %{role: "user", content: %{type: "text", text: text}}

  defp messages(items), do: %{messages: items}
end

defmodule OzMcp.E2E.ConformanceServer.Resources do
  use OzMcp.Config.Resource

  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

  resource "static-text" do
    uri "test://static-text"
    title "Static text"
    description "A resource with a text content"
    mime_type "text/plain"
  end

  resource "static-binary" do
    uri "test://static-binary"
    title "Static binary"
    description "A resource with a binary content"
    mime_type "image/png"
  end

  resource "watched-resource" do
    uri "test://watched-resource"
    title "Watched resource"
    description "A resource that a client can subscribe to"
    mime_type "text/plain"
  end

  @impl true
  def read(_ctx, %{"uri" => "test://static-text"}) do
    {:ok,
     %{
       contents: [
         %{
           uri: "test://static-text",
           mimeType: "text/plain",
           text: "This is the content of the static text resource."
         }
       ]
     }}
  end

  def read(_ctx, %{"uri" => "test://static-binary"}) do
    {:ok, %{contents: [%{uri: "test://static-binary", mimeType: "image/png", blob: @png}]}}
  end

  def read(_ctx, %{"uri" => "test://watched-resource"}) do
    {:ok,
     %{
       contents: [
         %{uri: "test://watched-resource", mimeType: "text/plain", text: "Watched content."}
       ]
     }}
  end
end

defmodule OzMcp.E2E.ConformanceServer.Templates do
  use OzMcp.Config.Template

  template "template-data" do
    uri_template "test://template/{id}/data"
    title "Template data"
    description "The data of an id"
    mime_type "application/json"
  end

  @impl true
  def read(_ctx, %{"uri" => uri}, "test://template/{id}/data", %{"id" => id}) do
    json = ~s({"id":"#{id}","templateTest":true,"data":"Data for ID: #{id}"})
    {:ok, %{contents: [%{uri: uri, mimeType: "application/json", text: json}]}}
  end
end

#
# The server that `test/e2e/support/serve.exs` starts for the official
# conformance tool. It declares the entities that the server scenarios call
# by name (`test_simple_text`, `test_simple_prompt`, `test://static-text`,
# ...), with the content that each scenario expects. The e2e suite does not
# use it.
#
defmodule OzMcp.E2E.ConformanceServer do
  use OzMcp.Config.Server

  alias OzMcp.E2E.ConformanceServer.{Prompts, Resources, Templates, Tools}

  server_info do
    name "conformance"
    version "1.0.0"
  end

  tools do
    tool Tools
  end

  resources do
    resource Resources
  end

  templates do
    template Templates
  end

  prompts do
    prompt Prompts
  end

  capabilities do
    logging %{}

    resources do
      subscribe true
    end

    completions %{}
  end
end
