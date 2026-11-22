#
# The bind stage of the POST and stdio pipelines: it finds the entity of
# the request, checks its arguments and applies the defaults and puts
# the result in `bound` of the context. The bind kind comes from the row
# of the method table.
#
# Hazard: a caller without a valid session learns nothing about the
# entities of the server.
#
defmodule OzMcp.Pipeline.Bind do
  @moduledoc false

  import OzMcp.Pipeline.Helpers,
    only: [
      completion_ref: 1,
      task_support_of: 1,
      tasks_capability_of: 1,
      tools_call_task_capable?: 1,
      type_name: 1
    ]

  alias OzMcp.Auth.Scopes
  alias OzMcp.{Catalog, Context, Method, Pipeline}
  alias OzMcp.Method.Table
  alias OzMcp.Pipeline.Bound
  alias OzMcp.Structs.PromptArgument
  alias OzMcp.Tasks
  alias OzMcp.Utils.JsonSchemaValidator

  @spec run(Context.t()) :: Pipeline.result()

  # A method without a row binds nothing, like the rows of kind `:none`.
  #
  def run(%{rpc_method: name} = context) do
    case Table.fetch(name) do
      {:ok, %Method{bind: kind}} -> bind(kind, context)
      :error -> bind(:none, context)
    end
  end

  defp bind(:tool, %{rpc_params: rpc_params} = context),
    do: tools_call(context, rpc_params["name"], rpc_params)

  defp bind(:prompt, %{rpc_params: rpc_params} = context),
    do: prompts_get(context, rpc_params["name"], rpc_params)

  defp bind(:resource, %{rpc_params: rpc_params} = context),
    do: resources_uri(context, rpc_params["uri"])

  defp bind(:completion, %{rpc_params: rpc_params} = context) do
    {:ok, {type, ref}} = completion_ref(rpc_params)

    with {:ok, module, entity} <- completion_module(context, type, ref),
         :ok <- completion_supported(module) do
      bound = %Bound{
        kind: :completion,
        module: module,
        entity: entity,
        params: rpc_params,
        required_scopes: Scopes.required(entity),
        completion: %{
          ref: {type, ref},
          argument: context.completion_argument,
          context: context.completion_context
        }
      }

      {:cont, %{context | bound: bound}}
    else
      {:error, code} -> Pipeline.halt(context, code)
      {:error, code, data} -> Pipeline.halt(context, code, data)
    end
  end

  # The scopes of a task are the scopes of its tool at the creation. An
  # unknown or expired task has no scope, so the stage does not tell a
  # caller whether a task exists.
  #
  defp bind(:task, %{rpc_params: %{"taskId" => task_id} = rpc_params} = context)
       when is_binary(task_id) do
    scopes =
      case Tasks.peek(context.instance, Tasks.owner_key(context), task_id) do
        {:ok, record} -> record.required_scopes || []
        {:error, _no_task_or_expired} -> []
      end

    bound = %Bound{kind: :task, name: task_id, params: rpc_params, required_scopes: scopes}
    {:cont, %{context | bound: bound}}
  end

  # A task method without a binary `taskId` binds like the list method.
  #
  defp bind(:task, context), do: bind(:task_list, context)

  defp bind(:task_list, %{rpc_params: rpc_params} = context) do
    bound = %Bound{
      kind: :task,
      name: rpc_params && rpc_params["taskId"],
      params: rpc_params || %{}
    }

    {:cont, %{context | bound: bound}}
  end

  defp bind(:none, context),
    do: {:cont, %{context | bound: %Bound{kind: :none, params: context.rpc_params || %{}}}}

  # The uri is not looked up: a resource that is gone can be unsubscribed.
  #
  defp bind(:resource_uri, context), do: bind(:none, context)

  defp tools_call(context, name, rpc_params) do
    catalog = Catalog.fetch(context.server)

    case Catalog.find_tool(catalog, name) do
      nil ->
        Pipeline.halt(context, :rpc_tool_not_found, %{"name" => name})

      {module, tool_config} ->
        schema = tool_config.inputSchema
        arguments = rpc_params["arguments"]

        with {:ok, arguments} <- check_arguments_type(arguments),
             {:ok, task, rpc_params} <- task_gate(context, tool_config, rpc_params),
             {:ok, arguments, input_errors, rpc_params} <-
               validate_input(catalog, module, name, schema, rpc_params, arguments) do
          bound = %Bound{
            kind: :tool,
            name: name,
            module: module,
            entity: tool_config,
            params: rpc_params,
            arguments: arguments || %{},
            input_errors: input_errors,
            required_scopes: Scopes.required(tool_config),
            task: task
          }

          {:cont, %{context | bound: bound}}
        else
          {:error, code} -> Pipeline.halt(context, code)
          {:error, code, data} -> Pipeline.halt(context, code, data)
        end
    end
  end

  defp check_arguments_type(arguments) when is_nil(arguments) or is_map(arguments),
    do: {:ok, arguments}

  defp check_arguments_type(arguments),
    do: {:error, :rpc_bad_arguments, type_error("arguments", arguments)}

  defp type_error(field, value),
    do: ["invalid type for argument '#{field}': expected 'object', got '#{type_name(value)}'"]

  # Task support gating runs before the argument schema: the task marker
  # alone decides, whatever the arguments look like.
  #
  defp task_gate(context, tool_config, rpc_params) do
    tasks = context.server.config().capabilities |> tasks_capability_of()
    task_meta = rpc_params["task"]
    task_support = task_support_of(tool_config)

    cond do
      is_nil(task_meta) and task_support == :required and tools_call_task_capable?(tasks) ->
        {:error, :rpc_method_not_found}

      is_nil(task_meta) ->
        {:ok, nil, rpc_params}

      not tools_call_task_capable?(tasks) ->
        {:ok, nil, Map.delete(rpc_params, "task")}

      task_support != :forbidden ->
        validate_task_metadata(task_meta, rpc_params)

      true ->
        {:error, :rpc_method_not_found}
    end
  end

  defp validate_task_metadata(task_meta, rpc_params) do
    cond do
      not is_map(task_meta) ->
        {:error, :rpc_bad_task_metadata}

      invalid_ttl?(Map.get(task_meta, "ttl")) ->
        {:error, :rpc_bad_task_metadata}

      true ->
        {:ok, %{ttl: Map.get(task_meta, "ttl")}, Map.delete(rpc_params, "task")}
    end
  end

  defp invalid_ttl?(nil), do: false

  # A ttl of 0 expires at once: the wire refuses it, like a negative or a
  # non-integer value.
  #
  defp invalid_ttl?(ttl), do: not is_integer(ttl) or ttl <= 0

  # A schema violation is a tool execution error, so the model can correct
  # itself. A task-augmented call keeps its task metadata and gets a task
  # with the same messages. A schema that does not compile is a server
  # defect: the bind halts, the client gets -32603 and the tool never
  # runs (a task is not created either).
  #
  # The root of a tool comes from the catalog, at boot; a root that the
  # catalog does not hold (a task record of another version of the code)
  # is compiled again at the request.
  #
  defp validate_input(catalog, module, name, schema, rpc_params, arguments) do
    with {:ok, root} <- Catalog.fetch_root(catalog, module, name, :input, schema),
         {:ok, validated_arguments} <-
           JsonSchemaValidator.validate(root, arguments, apply_defaults: true) do
      {:ok, validated_arguments, nil, Map.put(rpc_params, "arguments", validated_arguments)}
    else
      {:error, :invalid_schema} ->
        {:error, :rpc_invalid_tool_schema}

      {:error, errors} when is_list(errors) ->
        {:ok, arguments, errors, rpc_params}
    end
  end

  defp prompts_get(context, name, rpc_params) do
    case Catalog.find_prompt(Catalog.fetch(context.server), name) do
      nil ->
        Pipeline.halt(context, :rpc_prompt_not_found)

      {module, prompt} ->
        declared = prompt.arguments || []
        arguments = Map.get(rpc_params, "arguments") || %{}

        with {:ok, arguments} <- check_arguments_map(rpc_params, arguments),
             :ok <- check_unknown_arguments(declared, arguments),
             :ok <- check_missing_required(declared, arguments),
             :ok <- check_string_values(declared, arguments) do
          bound = %Bound{
            kind: :prompt,
            name: name,
            module: module,
            entity: prompt,
            params: rpc_params,
            arguments: arguments,
            required_scopes: Scopes.required(prompt)
          }

          {:cont, %{context | bound: bound}}
        else
          {:error, errors} -> Pipeline.halt(context, :rpc_bad_arguments, errors)
        end
    end
  end

  defp check_arguments_map(rpc_params, arguments) do
    case Map.get(rpc_params, "arguments") do
      nil ->
        {:ok, arguments}

      value when is_map(value) ->
        {:ok, value}

      value ->
        {:error, type_error("arguments", value)}
    end
  end

  defp check_unknown_arguments(declared, arguments) do
    declared_names = MapSet.new(declared, &prompt_argument_name/1)

    Enum.reduce(arguments, [], fn {name, _value}, acc ->
      if MapSet.member?(declared_names, name) do
        acc
      else
        ["unknown argument: '#{name}'" | acc]
      end
    end)
    |> errors_or_ok()
  end

  defp check_missing_required(declared, arguments) do
    Enum.reduce(declared, [], fn argument, acc ->
      name = prompt_argument_name(argument)

      if prompt_argument_required?(argument) and not Map.has_key?(arguments, name) do
        ["missing required argument: '#{name}'" | acc]
      else
        acc
      end
    end)
    |> errors_or_ok()
  end

  defp check_string_values(_declared, arguments) do
    Enum.reduce(arguments, [], fn {name, value}, acc ->
      if is_binary(value) do
        acc
      else
        [
          "invalid type for argument '#{name}': expected 'string', got '#{type_name(value)}'"
          | acc
        ]
      end
    end)
    |> errors_or_ok()
  end

  defp prompt_argument_name(%PromptArgument{name: name}), do: to_string(name)

  defp prompt_argument_required?(%PromptArgument{required: required}), do: required == true

  defp errors_or_ok([]), do: :ok

  defp errors_or_ok(errors), do: {:error, errors}

  defp resources_uri(context, uri) do
    catalog = Catalog.fetch(context.server)

    case Catalog.find_resource(catalog, uri) do
      nil ->
        case Catalog.find_template(catalog, uri) do
          nil ->
            Pipeline.halt(context, :rpc_resource_not_found, %{"uri" => uri})

          {module, template, params} ->
            bound = %Bound{
              kind: :template,
              name: uri,
              module: module,
              entity: template,
              params: context.rpc_params,
              uri_params: params,
              required_scopes: Scopes.required(template)
            }

            {:cont, %{context | bound: bound}}
        end

      {module, resource} ->
        bound = %Bound{
          kind: :resource,
          name: uri,
          module: module,
          entity: resource,
          params: context.rpc_params,
          required_scopes: Scopes.required(resource)
        }

        {:cont, %{context | bound: bound}}
    end
  end

  defp completion_module(context, :prompt, name) do
    case Catalog.find_prompt(Catalog.fetch(context.server), name) do
      nil -> {:error, :rpc_prompt_not_found}
      {module, prompt} -> {:ok, module, prompt}
    end
  end

  defp completion_module(context, :resource, uri) do
    catalog = Catalog.fetch(context.server)

    with nil <- Catalog.find_resource(catalog, uri),
         nil <- Catalog.find_template_by_ref(catalog, uri),
         nil <- Catalog.find_template(catalog, uri) do
      {:error, :rpc_resource_not_found, %{"uri" => uri}}
    else
      {module, entity} -> {:ok, module, entity}
      {module, entity, _params} -> {:ok, module, entity}
    end
  end

  defp completion_supported(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :complete, 4) do
      :ok
    else
      {:error, :rpc_method_not_found}
    end
  end
end
