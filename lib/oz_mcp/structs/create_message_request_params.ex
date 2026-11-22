defmodule OzMcp.Structs.CreateMessageRequestParams do
  @moduledoc """
  Helper module used to build the params of a `sampling/createMessage`
  request.

  _(MCP protocol: 2025-11-25)_

  `messages` is a list of `OzMcp.Structs.SamplingMessage` structs or maps.
  `tools` is a list of `OzMcp.Structs.Tool` structs or maps. `maxTokens` is
  required.

  Tool use follows the rules of the specification, checked by `build/1`:

    * a message that has a `tool_result` block has only `tool_result`
      blocks, has the role `user` and comes right after a message with the
      `tool_use` blocks it answers;
    * a message that has `tool_use` blocks has the role `assistant` and is
      followed by a message with a `tool_result` block for each of them (the
      same `toolUseId`).

  ## Short example:

  ```elixir
  %CreateMessageRequestParams{}
    |> CreateMessageRequestParams.messages([SamplingMessage.user("Hello")])
    |> CreateMessageRequestParams.max_tokens(100)
    |> CreateMessageRequestParams.build()
  ```

  Result:

  ```elixir
  %{
    messages: [%{role: "user", content: %{type: "text", text: "Hello"}}],
    maxTokens: 100
  }
  ```

  Specification: [CreateMessageRequestParams](https://modelcontextprotocol.io/specification/2025-11-25/schema#createmessagerequestparams)
  """

  use OzMcp.Structs.Wire,
    build: false,
    fields: [
      messages: {{:maps_of, OzMcp.Structs.SamplingMessage}, required: true},
      modelPreferences: {:any, type: quote(do: OzMcp.Structs.ModelPreferences.t() | map() | nil)},
      systemPrompt: :string,
      includeContext: {:any, type: quote(do: String.t() | atom() | nil)},
      temperature: :number,
      maxTokens: {:any, type: quote(do: pos_integer() | nil)},
      stopSequences: :list,
      metadata: :map,
      tools: {:any, type: quote(do: [OzMcp.Structs.Tool.t() | map()] | nil)},
      toolChoice: {:any, type: quote(do: OzMcp.Structs.ToolChoice.t() | map() | atom() | nil)},
      _meta: :meta,
      task: {:struct, OzMcp.Structs.TaskMetadata}
    ]

  alias OzMcp.Structs.{Builder, ModelPreferences, SamplingMessage, Tool, ToolChoice, Validate}

  @include_contexts ["none", "thisServer", "allServers"]

  @spec build(t()) :: map()
  def build(struct) do
    Validate.list(:messages, struct.messages)
    Validate.non_empty_string_or_nil(:systemPrompt, struct.systemPrompt)
    Validate.number_or_nil(:temperature, struct.temperature)
    Validate.list_or_nil(:stopSequences, struct.stopSequences)
    Validate.map_or_nil(:metadata, struct.metadata)
    Validate.list_or_nil(:tools, struct.tools)
    Validate.meta(:_meta, struct._meta)
    Validate.struct_or_nil(:task, OzMcp.Structs.TaskMetadata, struct.task)
    validate_messages_present(struct.messages)
    validate_max_tokens(struct.maxTokens)

    include_context = include_context_of(struct.includeContext)
    messages = Enum.map(struct.messages, &message/1)
    validate_tool_use(messages)

    %{messages: messages, maxTokens: struct.maxTokens}
    |> put(:modelPreferences, model_preferences_of(struct.modelPreferences))
    |> Builder.maybe_put(struct, :systemPrompt)
    |> put(:includeContext, include_context)
    |> Builder.maybe_put(struct, :temperature)
    |> Builder.maybe_put(struct, :stopSequences)
    |> Builder.maybe_put(struct, :metadata)
    |> put(:tools, tools_of(struct.tools))
    |> put(:toolChoice, tool_choice_of(struct.toolChoice))
    |> Builder.maybe_meta(struct)
    |> put_task(struct)
  end

  defp put_task(result, %{task: nil}), do: result

  defp put_task(result, struct) do
    Map.put(result, :task, OzMcp.Structs.TaskMetadata.build(struct.task))
  end

  defp put(result, _key, nil), do: result
  defp put(result, key, value), do: Map.put(result, key, value)

  defp validate_messages_present([_ | _]), do: :ok

  defp validate_messages_present(_messages) do
    raise ArgumentError, "The 'messages' field is required and cannot be empty"
  end

  defp validate_max_tokens(max_tokens) when is_integer(max_tokens) and max_tokens > 0, do: :ok

  defp validate_max_tokens(_max_tokens) do
    raise ArgumentError, "The 'maxTokens' field is required and must be a positive integer"
  end

  defp include_context_of(nil), do: nil
  defp include_context_of(:none), do: "none"
  defp include_context_of(:this_server), do: "thisServer"
  defp include_context_of(:all_servers), do: "allServers"

  defp include_context_of(value) when value in @include_contexts, do: value

  defp include_context_of(_value) do
    raise ArgumentError,
          "The 'includeContext' field must be one of :none, :this_server, :all_servers"
  end

  defp message(%SamplingMessage{} = message), do: SamplingMessage.build(message)
  defp message(%{} = message) when not is_struct(message), do: message

  defp message(other) do
    raise ArgumentError,
          "'messages' elements must be SamplingMessage structs or maps, got: #{inspect(other)}"
  end

  defp model_preferences_of(nil), do: nil
  defp model_preferences_of(%ModelPreferences{} = p), do: ModelPreferences.build(p)
  defp model_preferences_of(%{} = p) when not is_struct(p), do: p

  defp model_preferences_of(other) do
    raise ArgumentError,
          "The 'modelPreferences' field must be a ModelPreferences struct or a map, " <>
            "got: #{inspect(other)}"
  end

  defp tools_of(nil), do: nil
  defp tools_of([]), do: nil
  defp tools_of(tools), do: Enum.map(tools, &tool/1)

  defp tool(%Tool{} = tool), do: Tool.build(tool)
  defp tool(%{} = tool) when not is_struct(tool), do: tool

  defp tool(other) do
    raise ArgumentError, "'tools' elements must be Tool structs or maps, got: #{inspect(other)}"
  end

  defp tool_choice_of(nil), do: nil
  defp tool_choice_of(%ToolChoice{} = choice), do: ToolChoice.build(choice)
  defp tool_choice_of(%{} = choice) when not is_struct(choice), do: choice
  defp tool_choice_of(mode) when is_atom(mode), do: ToolChoice.build(%ToolChoice{mode: mode})

  defp tool_choice_of(other) do
    raise ArgumentError,
          "The 'toolChoice' field must be a ToolChoice struct, a map or a mode, got: #{inspect(other)}"
  end

  # ---- Tool use rules ----

  defp validate_tool_use(messages), do: validate_tool_use(messages, [])

  # `pending` are the tool_use ids of the previous message that need a result.
  #
  defp validate_tool_use([], []), do: :ok

  defp validate_tool_use([], _pending) do
    raise ArgumentError, "a message with 'tool_use' content must be followed by its 'tool_result'"
  end

  defp validate_tool_use([message | rest], pending) do
    blocks = blocks(message)
    types = Enum.map(blocks, &type/1)

    if "tool_result" in types and Enum.any?(types, &(&1 != "tool_result")) do
      raise ArgumentError,
            "a message with 'tool_result' content must have only 'tool_result' content"
    end

    result_ids = for b <- blocks, type(b) == "tool_result", do: get(b, :toolUseId)
    use_ids = for b <- blocks, type(b) == "tool_use", do: get(b, :id)

    validate_role(message, result_ids, use_ids)

    cond do
      pending != [] and Enum.sort(result_ids) != Enum.sort(pending) ->
        raise ArgumentError,
              "the message after 'tool_use' content must have a 'tool_result' for each " <>
                "'tool_use' id #{inspect(pending)}"

      pending == [] and result_ids != [] ->
        raise ArgumentError,
              "a message with 'tool_result' content must come right after the " <>
                "'tool_use' content it answers"

      true ->
        validate_tool_use(rest, use_ids)
    end
  end

  defp validate_role(message, result_ids, use_ids) do
    role = message |> get(:role) |> to_string()

    if result_ids != [] and role != "user" do
      raise ArgumentError, "a message with 'tool_result' content must have the role 'user'"
    end

    if use_ids != [] and role != "assistant" do
      raise ArgumentError, "a message with 'tool_use' content must have the role 'assistant'"
    end
  end

  defp blocks(message) do
    case get(message, :content) do
      list when is_list(list) -> list
      nil -> []
      block -> [block]
    end
  end

  defp type(block), do: get(block, :type)

  defp get(%{} = map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp get(_other, _key), do: nil
end
