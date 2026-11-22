defmodule OzMcp.Structs.SurfaceTest do
  use ExUnit.Case, async: true

  @surface %{
    OzMcp.Structs.Annotations => [
      audience: 2,
      build: 1,
      check: 1,
      check: 3,
      last_modified: 2,
      priority: 2,
      validate_priority: 1
    ],
    OzMcp.Structs.AudioContent => [
      _meta: 2,
      annotations: 2,
      build: 1,
      check_map: 1,
      data: 2,
      mime_type: 2
    ],
    OzMcp.Structs.BlobResourceContents => [
      _meta: 2,
      blob: 2,
      build: 1,
      check: 1,
      check_map: 1,
      mime_type: 2,
      uri: 2
    ],
    OzMcp.Structs.BooleanSchema => [build: 1, default: 2, description: 2, title: 2],
    OzMcp.Structs.CallToolResult => [
      _meta: 2,
      build: 1,
      content: 2,
      extras: 2,
      is_error: 2,
      structured_content: 2
    ],
    OzMcp.Structs.CompleteResult => [_meta: 2, build: 1, completion: 2],
    OzMcp.Structs.Completion => [build: 1, check_map: 1, has_more: 2, total: 2, values: 2],
    OzMcp.Structs.CreateMessageRequestParams => [
      _meta: 2,
      build: 1,
      include_context: 2,
      max_tokens: 2,
      messages: 2,
      metadata: 2,
      model_preferences: 2,
      stop_sequences: 2,
      system_prompt: 2,
      task: 2,
      temperature: 2,
      tool_choice: 2,
      tools: 2
    ],
    OzMcp.Structs.CreateTaskResult => [_meta: 2, build: 1, extras: 2, task: 2],
    OzMcp.Structs.ElicitRequestFormParams => [
      _meta: 2,
      build: 1,
      message: 2,
      requested_schema: 2,
      task: 2
    ],
    OzMcp.Structs.ElicitRequestURLParams => [
      _meta: 2,
      build: 1,
      elicitation_id: 2,
      message: 2,
      task: 2,
      url: 2
    ],
    OzMcp.Structs.ElicitationSchema => [build: 1, properties: 2, property: 3, required: 2],
    OzMcp.Structs.EmbeddedResource => [
      _meta: 2,
      annotations: 2,
      build: 1,
      check_map: 1,
      resource: 2
    ],
    OzMcp.Structs.EnumSchema => [build: 1, default: 2, description: 2, options: 2, title: 2],
    OzMcp.Structs.GetPromptResult => [_meta: 2, build: 1, description: 2, messages: 2],
    OzMcp.Structs.Icon => [
      build: 1,
      check: 1,
      mime_type: 2,
      sizes: 2,
      src: 2,
      theme: 2
    ],
    OzMcp.Structs.ImageContent => [
      _meta: 2,
      annotations: 2,
      build: 1,
      check_map: 1,
      data: 2,
      mime_type: 2
    ],
    OzMcp.Structs.Implementation => [
      build: 1,
      description: 2,
      icons: 2,
      name: 2,
      title: 2,
      version: 2,
      website_url: 2
    ],
    OzMcp.Structs.InitializeResult => [
      _meta: 2,
      build: 1,
      capabilities: 2,
      extras: 2,
      instructions: 2,
      protocol_version: 2,
      server_info: 2
    ],
    OzMcp.Structs.ModelPreferences => [
      build: 1,
      cost_priority: 2,
      hints: 2,
      intelligence_priority: 2,
      speed_priority: 2
    ],
    OzMcp.Structs.MultiSelectEnumSchema => [
      build: 1,
      default: 2,
      description: 2,
      max_items: 2,
      min_items: 2,
      options: 2,
      title: 2
    ],
    OzMcp.Structs.NotificationParams => [_meta: 2, build: 1],
    OzMcp.Structs.NumberSchema => [
      build: 1,
      default: 2,
      description: 2,
      maximum: 2,
      minimum: 2,
      title: 2,
      type: 2
    ],
    OzMcp.Structs.Prompt => [
      _meta: 2,
      arguments: 2,
      build: 1,
      description: 2,
      extras: 2,
      icons: 2,
      name: 2,
      required_scopes: 2,
      title: 2
    ],
    OzMcp.Structs.PromptArgument => [build: 1, description: 2, name: 2, required: 2, title: 2],
    OzMcp.Structs.PromptMessage => [build: 1, check: 1, content: 2, role: 2],
    OzMcp.Structs.ReadResourceResult => [_meta: 2, build: 1, contents: 2, extras: 2],
    OzMcp.Structs.RelatedTaskMetadata => [build: 1, task_id: 2],
    OzMcp.Structs.Resource => [
      _meta: 2,
      annotations: 2,
      build: 1,
      description: 2,
      extras: 2,
      icons: 2,
      mime_type: 2,
      name: 2,
      required_scopes: 2,
      size: 2,
      title: 2,
      uri: 2
    ],
    OzMcp.Structs.ResourceLink => [
      _meta: 2,
      annotations: 2,
      build: 1,
      check_map: 1,
      description: 2,
      icons: 2,
      mime_type: 2,
      name: 2,
      size: 2,
      title: 2,
      uri: 2
    ],
    OzMcp.Structs.ResourceTemplate => [
      _meta: 2,
      annotations: 2,
      build: 1,
      description: 2,
      extras: 2,
      icons: 2,
      mime_type: 2,
      name: 2,
      required_scopes: 2,
      title: 2,
      uri_template: 2
    ],
    OzMcp.Structs.Root => [_meta: 2, build: 1, name: 2, uri: 2],
    OzMcp.Structs.SamplingMessage => [
      _meta: 2,
      assistant: 1,
      build: 1,
      content: 2,
      role: 2,
      user: 1
    ],
    OzMcp.Structs.ServerCapabilities => [
      build: 1,
      completions: 2,
      experimental: 2,
      logging: 2,
      resources: 2,
      tasks: 4
    ],
    OzMcp.Structs.StringSchema => [
      build: 1,
      default: 2,
      description: 2,
      format: 2,
      max_length: 2,
      min_length: 2,
      title: 2
    ],
    OzMcp.Structs.Task => [
      build: 1,
      created_at: 2,
      last_updated_at: 2,
      poll_interval: 2,
      status: 2,
      status_message: 2,
      task_id: 2,
      ttl: 2
    ],
    OzMcp.Structs.TaskMetadata => [build: 1, ttl: 2],
    OzMcp.Structs.TextContent => [_meta: 2, annotations: 2, build: 1, check_map: 1, text: 2],
    OzMcp.Structs.TextResourceContents => [
      _meta: 2,
      build: 1,
      check: 1,
      check_map: 1,
      mime_type: 2,
      text: 2,
      uri: 2
    ],
    OzMcp.Structs.Tool => [
      _meta: 2,
      annotations: 2,
      build: 1,
      description: 2,
      execution: 2,
      extras: 2,
      icons: 2,
      input_schema: 2,
      name: 2,
      output_schema: 2,
      required_scopes: 2,
      title: 2
    ],
    OzMcp.Structs.ToolAnnotations => [
      build: 1,
      destructive_hint: 2,
      idempotent_hint: 2,
      open_world_hint: 2,
      read_only_hint: 2,
      title: 2
    ],
    OzMcp.Structs.ToolChoice => [build: 1, mode: 2],
    OzMcp.Structs.ToolExecution => [
      build: 1,
      immediate_response: 2,
      poll_interval: 2,
      task_support: 2
    ],
    OzMcp.Structs.ToolResultContent => [
      _meta: 2,
      build: 1,
      content: 2,
      is_error: 2,
      structured_content: 2,
      tool_use_id: 2
    ],
    OzMcp.Structs.ToolUseContent => [_meta: 2, build: 1, id: 2, input: 2, name: 2]
  }

  for {module, functions} <- @surface do
    test "#{inspect(module)} keeps its public functions" do
      public =
        unquote(module).__info__(:functions)
        |> Enum.reject(fn {name, _arity} ->
          name |> Atom.to_string() |> String.starts_with?("__")
        end)
        |> Enum.sort()

      assert public == Enum.sort(unquote(functions))
    end

    test "#{inspect(module)} keeps its t/0 type" do
      {:ok, types} = Code.Typespec.fetch_types(unquote(module))

      assert Enum.any?(types, fn
               {:type, {:t, _, _}} -> true
               _ -> false
             end)
    end
  end
end
