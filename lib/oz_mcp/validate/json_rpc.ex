#
# The JSON-RPC stage of the POST and stdio pipelines: `validate/1` checks
# the envelope of one message and fills the context with its parts. A
# refused message gets an error in the context; the stage answers no
# client.
#
defmodule OzMcp.Validate.JsonRpc do
  @moduledoc false

  import OzMcp.Pipeline.Helpers, only: [completion_ref: 1, type_name: 1]

  alias OzMcp.{Context, Pipeline, Protocol}
  alias OzMcp.LogLevel
  alias OzMcp.Method
  alias OzMcp.Method.{Capabilities, Table}

  # The uri and taskId bind kinds come from the method table.
  #
  @uri_methods for %Method{name: name, bind: kind} <- Table.all(),
                   kind in [:resource, :resource_uri],
                   do: name
  @task_id_methods for %Method{name: name, bind: :task} <- Table.all(), do: name

  @spec validate(Context.t()) :: Pipeline.result()
  def validate(context) do
    rpc_params = rpc_params(context.rpc)

    context =
      context
      |> Map.put(:rpc_kind, OzMcp.Utils.JsonRpc.kind(context.rpc))
      |> Map.put(:rpc_id, key(context.rpc, "id"))
      |> Map.put(:rpc_method, key(context.rpc, "method"))
      |> Map.put(:rpc_params, rpc_params)
      |> Map.put(:progress_token, progress_token(rpc_params))

    if response?(context.rpc) do
      finish(response(context))
    else
      context
      |> envelope()
      |> require_params_presence()
      |> capabilities()
      |> id()
      |> meta()
      |> params()
      |> finish()
    end
  end

  defp finish(%{error: nil} = context), do: {:cont, context}

  defp finish(%{error: error} = context) when not is_nil(error), do: {:halt, context}

  # A message with no method that carries a result or an error is the
  # answer to a request the server sent, not a request.
  #
  defp response?(rpc) when is_map(rpc) do
    not Map.has_key?(rpc, "method") and
      (Map.has_key?(rpc, "result") or Map.has_key?(rpc, "error"))
  end

  defp response?(_rpc), do: false

  # An error response may carry no `id` or a null `id`: no request can
  # wait for it, so the handler only logs the code. A `result` with no
  # `id` stays an invalid request.
  #
  defp response(%{rpc: rpc, rpc_id: id} = context)
       when is_nil(id) and not is_map_key(rpc, "result") do
    with "2.0" <- key(rpc, "jsonrpc"),
         %{"code" => code, "message" => message} = error
         when is_integer(code) and is_binary(message) <- rpc["error"] do
      context
      |> Map.put(:rpc_id, nil)
      |> Map.put(:rpc_response, {:orphan_error, error})
    else
      _ -> Context.put_error(context, :rpc_invalid_request)
    end
  end

  defp response(%{rpc: rpc, rpc_id: id} = context) do
    cond do
      key(rpc, "jsonrpc") != "2.0" or not (is_binary(id) or is_integer(id)) ->
        Context.put_error(context, :rpc_invalid_request)

      Map.has_key?(rpc, "result") and Map.has_key?(rpc, "error") ->
        Context.put_error(context, :rpc_invalid_request)

      Map.has_key?(rpc, "result") ->
        case rpc["result"] do
          %{} = result -> Map.put(context, :rpc_response, {:ok, result})
          _ -> Context.put_error(context, :rpc_invalid_request)
        end

      true ->
        case rpc["error"] do
          %{"code" => code, "message" => message} = error
          when is_integer(code) and is_binary(message) ->
            Map.put(context, :rpc_response, {:error, error})

          _ ->
            Context.put_error(context, :rpc_invalid_request)
        end
    end
  end

  defp key(nil, _key), do: nil

  defp key(rpc, key) do
    case Map.fetch(rpc, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  # A JSON null for a member of `params` is a missing member. A deeper
  # level does not change: the nil of an argument belongs to the tool.
  #
  defp rpc_params(rpc) do
    case key(rpc, "params") do
      %{} = params -> Map.reject(params, fn {_name, value} -> is_nil(value) end)
      params -> params
    end
  end

  defp progress_token(%{"_meta" => %{"progressToken" => token}})
       when is_binary(token) or is_integer(token),
       do: token

  defp progress_token(_params), do: nil

  defp require_params_presence(context) when not is_nil(context.error), do: context

  defp require_params_presence(%{rpc_method: rpc_method, rpc_params: nil} = context) do
    case Table.fetch(rpc_method) do
      {:ok, %Method{params: :required}} -> Context.put_error(context, :rpc_missing_params)
      _other -> context
    end
  end

  defp require_params_presence(context), do: context

  # A method that the table does not hold passes: the handler answers it
  # with `method not found`.
  #
  defp capabilities(context) when not is_nil(context.error), do: context

  defp capabilities(%{rpc_method: rpc_method} = context) do
    with {:ok, %Method{gates: gates}} <- Table.fetch(rpc_method),
         false <- Capabilities.allowed?(gates, context.server.config()) do
      Context.put_error(context, :rpc_method_not_found)
    else
      _allowed_or_unknown -> context
    end
  end

  defp envelope(context) when not is_nil(context.error), do: context

  defp envelope(
         %{rpc: rpc, rpc_id: rpc_id, rpc_method: rpc_method, rpc_params: rpc_params} = context
       ) do
    cond do
      key(rpc, "jsonrpc") != "2.0" ->
        Context.put_error(context, :rpc_invalid_request)

      not valid_method?(rpc_method) ->
        Context.put_error(context, :rpc_invalid_request)

      not valid_id?(rpc) ->
        Context.put_error(context, :rpc_invalid_request)

      # A method that the server knows only as a notification does not
      # exist as a request.
      #
      notification_method?(rpc_method) and not is_nil(rpc_id) ->
        Context.put_error(context, :rpc_method_not_found)

      not valid_params?(rpc_params) ->
        Context.put_error(context, :rpc_invalid_request)

      true ->
        context
    end
  end

  defp valid_method?(method) when is_binary(method) and byte_size(method) > 0, do: true
  defp valid_method?(_method), do: false

  defp notification_method?("notifications/" <> _rest), do: true
  defp notification_method?(_method), do: false

  # A present `id` must be a string or an integer.
  #
  defp valid_id?(%{"id" => id}), do: is_binary(id) or is_integer(id)
  defp valid_id?(_rpc), do: true

  defp valid_params?(nil), do: true
  defp valid_params?(params) when is_map(params), do: true
  defp valid_params?(_params), do: false

  defp id(context) when not is_nil(context.error), do: context

  defp id(%{rpc_id: nil, rpc_method: rpc_method} = context) when is_binary(rpc_method) do
    if notification_method?(rpc_method) do
      context
    else
      Context.put_error(context, :rpc_missing_id)
    end
  end

  defp id(context), do: context

  # `_meta` is an object in every message that carries `params`. A null
  # for `_meta` or `progressToken` is a missing member.
  #
  defp meta(context) when not is_nil(context.error), do: context

  defp meta(%{rpc_params: params} = context) when is_map(params) do
    case Map.get(params, "_meta") do
      nil ->
        context

      %{} = meta ->
        case Map.get(meta, "progressToken") do
          nil ->
            context

          token when is_binary(token) or is_integer(token) ->
            context

          _token ->
            Context.put_error(context, :rpc_invalid_progress_token)
        end

      _meta ->
        Context.put_error(context, :rpc_invalid_meta)
    end
  end

  defp meta(context), do: context

  defp params(context) when not is_nil(context.error), do: context

  defp params(%{rpc_method: "initialize", rpc_params: params} = context)
       when is_map(params) or is_nil(params) do
    requested = params && Map.get(params, "protocolVersion")
    client_info = params && Map.get(params, "clientInfo")

    # A missing member and JSON null give no capabilities.
    #
    capabilities =
      case params && Map.get(params, "capabilities") do
        nil -> %{}
        value -> value
      end

    # `Implementation` requires `name` and `version`; any string is valid.
    #
    valid_client_info? =
      is_map(client_info) and
        is_binary(Map.get(client_info, "name")) and
        is_binary(Map.get(client_info, "version"))

    cond do
      not is_binary(requested) or requested == "" ->
        Context.put_error(context, :rpc_invalid_protocol_version)

      not valid_client_info? ->
        Context.put_error(context, :rpc_invalid_client_info)

      not is_map(capabilities) ->
        Context.put_error(context, :rpc_invalid_capabilities)

      true ->
        negotiated =
          if Protocol.supported?(requested),
            do: requested,
            else: Protocol.latest()

        context
        |> Map.put(:negotiated_protocol_version, negotiated)
        |> Map.put(:client_info, client_info)
        |> Map.put(:client_capabilities, capabilities)
    end
  end

  defp params(%{rpc_method: rpc_method, rpc_params: rpc_params} = context)
       when rpc_method in @uri_methods and is_map(rpc_params) do
    if is_binary(rpc_params["uri"]),
      do: context,
      else: Context.put_error(context, :rpc_missing_uri_parameter)
  end

  defp params(%{rpc_method: "tools/call", rpc_params: rpc_params} = context)
       when is_map(rpc_params) do
    arguments = rpc_params["arguments"]

    cond do
      not is_binary(rpc_params["name"]) ->
        Context.put_error(context, :rpc_missing_name_parameter)

      not is_nil(arguments) and not is_map(arguments) ->
        Context.put_error(context, :rpc_bad_arguments, [
          "invalid type for argument 'arguments': expected 'object', " <>
            "got '#{type_name(arguments)}'"
        ])

      true ->
        context
    end
  end

  defp params(%{rpc_method: "prompts/get", rpc_params: rpc_params} = context)
       when is_map(rpc_params) do
    if is_binary(rpc_params["name"]),
      do: context,
      else: Context.put_error(context, :rpc_missing_name_parameter)
  end

  defp params(%{rpc_method: rpc_method, rpc_params: rpc_params} = context)
       when rpc_method in @task_id_methods and is_map(rpc_params) do
    case Map.fetch(rpc_params, "taskId") do
      {:ok, task_id} when is_binary(task_id) and byte_size(task_id) > 0 ->
        Map.put(context, :task_id, task_id)

      _ ->
        Context.put_error(context, :rpc_missing_taskid_parameter)
    end
  end

  defp params(%{rpc_method: "tasks/list", rpc_params: rpc_params} = context)
       when is_map(rpc_params) do
    case Map.get(rpc_params, "cursor") do
      nil -> context
      cursor when is_binary(cursor) -> Map.put(context, :tasks_cursor, cursor)
      _ -> Context.put_error(context, :rpc_invalid_cursor)
    end
  end

  defp params(%{rpc_method: "logging/setLevel", rpc_params: rpc_params} = context)
       when is_map(rpc_params) do
    level =
      case rpc_params do
        %{"level" => raw} -> parse_log_level(raw)
        _ -> nil
      end

    case level do
      nil ->
        Context.put_error(context, :rpc_invalid_log_level)

      level ->
        Map.put(context, :log_level, level)
    end
  end

  defp params(%{rpc_method: "completion/complete", rpc_params: rpc_params} = context)
       when is_map(rpc_params) do
    with {:ok, {_type, ref}} <- completion_ref(rpc_params),
         {:ok, argument} <- completion_argument(rpc_params),
         {:ok, completion_context} <- completion_context(rpc_params) do
      context
      |> Map.put(:completion_ref, ref)
      |> Map.put(:completion_argument, argument)
      |> Map.put(:completion_context, completion_context)
    else
      {:error, code} -> Context.put_error(context, code)
      {:error, code, data} -> Context.put_error(context, code, data)
    end
  end

  defp params(context), do: context

  defp completion_argument(%{"argument" => %{"name" => name, "value" => value}})
       when is_binary(name) and byte_size(name) > 0 and is_binary(value),
       do: {:ok, %{"name" => name, "value" => value}}

  defp completion_argument(_rpc_params) do
    {:error, :rpc_bad_arguments,
     [
       "invalid 'argument': expected an object with a non-empty string 'name' and a string 'value'"
     ]}
  end

  defp completion_context(%{"context" => context}) when is_map(context) do
    case Map.get(context, "arguments") do
      nil ->
        {:ok, nil}

      arguments when is_map(arguments) ->
        if Enum.all?(arguments, fn {_name, value} -> is_binary(value) end) do
          {:ok, arguments}
        else
          {:error, :rpc_bad_arguments,
           ["invalid 'context.arguments': every value must be a string"]}
        end

      _ ->
        {:error, :rpc_bad_arguments, ["invalid 'context.arguments': expected an object"]}
    end
  end

  defp completion_context(%{"context" => _context}) do
    {:error, :rpc_bad_arguments, ["invalid 'context': expected an object"]}
  end

  defp completion_context(_rpc_params), do: {:ok, nil}

  defp parse_log_level(raw) when is_binary(raw) do
    case Enum.find(LogLevel.levels(), &(&1 == String.to_existing_atom(raw))) do
      nil -> nil
      level -> level
    end
  rescue
    ArgumentError -> nil
  end

  defp parse_log_level(_), do: nil
end
