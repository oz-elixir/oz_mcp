defmodule OzMcp.Handler.Tools do
  @moduledoc false

  alias OzMcp.Context
  alias OzMcp.Handler.{Invoke, Output, Reply}
  alias OzMcp.Pipeline.Bound
  alias OzMcp.Tasks
  alias OzMcp.Utils.JsonRpc

  alias OzMcp.Structs.{CallToolResult, CreateTaskResult, TextContent}

  require Logger

  @immediate_key "io.modelcontextprotocol/model-immediate-response"

  # A schema violation is a tool execution error, not a protocol error:
  # the client receives a successful tools/call response whose result
  # carries isError: true and the violation messages, so the model can
  # read them and self correct. The tool callback is never executed.
  #
  @spec call(Context.t(), stream) :: {OzMcp.Handler.response(), stream} when stream: term()
  def call(%{bound: %Bound{input_errors: errors, task: nil}} = context, stream)
      when not is_nil(errors) do
    Reply.success(context, input_error_result(errors), stream)
  end

  # A task-augmented call keeps its shape when the arguments fail input
  # validation: the client still receives a CreateTaskResult and the task
  # is created already failed, with the same isError tool result a plain
  # call would have returned. The tool callback is never executed.
  #
  def call(%{bound: %Bound{input_errors: errors, task: task_meta}} = context, stream)
      when not is_nil(errors) and not is_nil(task_meta) do
    %Bound{module: module, name: name} = context.bound

    response =
      create_task_response(context, %{
        session_id: context.session_id,
        tool: {module, name},
        ttl: task_meta.ttl,
        progress_token: context.progress_token,
        client_capabilities: context.client_capabilities,
        principal: context.principal,
        required_scopes: context.bound.required_scopes,
        settled:
          {:failed, "The tool execution reported an error.", {:ok, input_error_result(errors)}}
      })

    {response, stream}
  end

  def call(
        %{
          bound: %Bound{module: module, entity: tool_config, task: nil, params: params}
        } = context,
        stream
      ) do
    #
    # The bind stage checked the params and the tool (OzMcp.Pipeline.Bind).
    # The callback runs in isolation: a crash or a deadline overrun
    # (request_timeout_ms opt) answers a -32603 internal error, a
    # notifications/cancelled a -32800 error (see OzMcp.Handler.Invoke).
    # The outputSchema root is built before the tool runs: a broken
    # outputSchema is a server defect and the result of the tool is
    # checked against the same root (see OzMcp.Handler.Output).
    #
    name = params["name"]
    schema = Output.schema(tool_config)

    case Output.fetch_root(context.server, module, name, schema) do
      {:ok, output_root} ->
        ctx = Context.to_ctx(context)

        {outcome, stream} =
          Invoke.run(
            context,
            fn ->
              module.call(ctx, params)
            end,
            stream: stream,
            telemetry_name: name,
            check: output_check(context, output_root)
          )

        Reply.outcome(context, outcome, stream)

      {:error, :invalid_schema} ->
        Reply.error(context, -32603, "internal error", stream)
    end
  end

  # With a task-augmented tools/call, the tool result is never returned
  # here: the client receives a CreateTaskResult. The outputSchema root is
  # built before the task is created, as on the synchronous path; the task
  # process checks the result against the same root (see OzMcp.Tasks).
  #
  def call(
        %{
          bound: %Bound{module: module, entity: tool_config, task: task_meta, params: params}
        } = context,
        stream
      ) do
    name = params["name"]
    schema = Output.schema(tool_config)

    case Output.fetch_root(context.server, module, name, schema) do
      {:ok, _root} ->
        attrs = %{
          session_id: context.session_id,
          tool: {module, name},
          request: params,
          ttl: task_meta.ttl,
          progress_token: context.progress_token,
          client_capabilities: context.client_capabilities,
          principal: context.principal,
          required_scopes: context.bound.required_scopes,
          output_schema: schema,
          poll_interval: poll_interval_of(tool_config)
        }

        {create_task_response(context, attrs), stream}

      {:error, :invalid_schema} ->
        Reply.error(context, -32603, "internal error", stream)
    end
  end

  defp text_content(text), do: %TextContent{} |> TextContent.text(text)

  # The option `check_output_schemas` turns this check of the result off.
  #
  defp output_check(%{config: %{opts: %{check_output_schemas: false}}}, _root), do: nil
  defp output_check(_context, output_root), do: fn result -> Output.check(output_root, result) end

  defp input_error_result(errors) do
    %CallToolResult{}
    |> CallToolResult.content([text_content(Enum.join(errors, "\n"))])
    |> CallToolResult.is_error(true)
    |> CallToolResult.build()
  end

  # The poll interval that the execution of the tool declares (nil when
  # the tool gives none): the create of the task puts it in the record,
  # ahead of the instance default. The bound entity of a test or of a
  # broken server config can be nil.
  #
  defp poll_interval_of(tool), do: execution_field(tool, :poll_interval)

  defp create_task_response(context, attrs) do
    case Tasks.create(context.instance, attrs) do
      {:ok, task} ->
        result =
          %CreateTaskResult{}
          |> CreateTaskResult.task(task)
          |> put_immediate_response(immediate_response_of(context.bound.entity))
          |> CreateTaskResult.build()

        {:rpc_success, JsonRpc.success(context.rpc_id, result)}

      # A limit of the runtime options (max_tasks_per_session,
      # max_tasks_per_principal, max_task_records_per_owner or
      # max_task_bytes_per_owner) refused the task. It is not a defect of
      # the server, so the code is -32000 (like "too many sessions") and
      # no warning log goes with the answer. The data tells which limit.
      #
      {:error, {:too_many_tasks, limit}} ->
        {:rpc_error,
         JsonRpc.error(context.rpc_id, -32000, "too many tasks", %{
           "limit" => Atom.to_string(limit)
         })}

      other ->
        Logger.warning("tools/call task creation failed: #{inspect(other)}")
        {:rpc_error, JsonRpc.error(context.rpc_id, -32603, "cannot create task")}
    end
  end

  defp put_immediate_response(result, nil), do: result

  defp put_immediate_response(result, text),
    do: CreateTaskResult._meta(result, %{@immediate_key => text})

  defp immediate_response_of(tool), do: execution_field(tool, :immediate_response)

  defp execution_field(%{execution: %{} = execution}, field), do: Map.get(execution, field)
  defp execution_field(_tool, _field), do: nil
end
