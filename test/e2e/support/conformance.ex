#
# Validation of the server messages against the official schema of the
# MCP revision that the framework implements.
#
# The module builds each definition of the schema one time and keeps the
# compiled root in `:persistent_term`. A validation error raises an
# `ExUnit.AssertionError` whose message gives the definition and the
# errors of the validator.
#
defmodule OzMcp.E2E.Conformance do
  @path "test/fixtures/mcp/2025-11-25/schema.json"
  @external_resource @path
  @document @path |> File.read!() |> JSON.decode!()

  @defs_key if Map.has_key?(@document, "$defs"), do: "$defs", else: "definitions"

  @results %{
    "initialize" => "InitializeResult",
    "ping" => "EmptyResult",
    "tools/list" => "ListToolsResult",
    "tools/call" => ["CallToolResult", "CreateTaskResult"],
    "resources/list" => "ListResourcesResult",
    "resources/templates/list" => "ListResourceTemplatesResult",
    "resources/read" => "ReadResourceResult",
    "resources/subscribe" => "EmptyResult",
    "resources/unsubscribe" => "EmptyResult",
    "prompts/list" => "ListPromptsResult",
    "prompts/get" => "GetPromptResult",
    "completion/complete" => "CompleteResult",
    "logging/setLevel" => "EmptyResult",
    "tasks/get" => "GetTaskResult",
    "tasks/list" => "ListTasksResult",
    "tasks/cancel" => "CancelTaskResult",
    "tasks/result" => "GetTaskPayloadResult"
  }

  # The payload of `tasks/result` has the result type of the original
  # request. The schema type of the method alone accepts any object, so
  # the payload gets a second check. The server makes a task only for
  # `tools/call`, so the type of the payload is fixed here.
  #
  @payloads %{"tasks/result" => "CallToolResult"}

  @type error :: %{
          required(:definition) => String.t(),
          required(:errors) => [map()]
        }

  # Validates `result` against the result type of `method`. For
  # `tasks/result`, the result must also match the result type of the
  # original request. Returns `:ok` or a list of errors, one error per
  # candidate definition.
  #
  @spec check_result(String.t(), term()) :: :ok | [error()]
  def check_result(method, result) do
    with :ok <- check_named(@results, method, result) do
      check_named(@payloads, method, result)
    end
  end

  # Validates a server notification against the union type of the schema.
  #
  @spec check_notification(term()) :: :ok | [error()]
  def check_notification(message), do: check_any(["ServerNotification"], message)

  # Validates a server request against the union type of the schema.
  #
  @spec check_server_request(term()) :: :ok | [error()]
  def check_server_request(message), do: check_any(["ServerRequest"], message)

  # Validates an error response against the error response definition of
  # the schema.
  #
  @spec check_error_response(term()) :: :ok | [error()]
  def check_error_response(message), do: check_any(["JSONRPCErrorResponse"], message)

  # Validates `result` against the result type of `method`. For
  # `tasks/result`, the result must also match the result type of the
  # original request. Raises `ExUnit.AssertionError` when the result does
  # not conform.
  #
  @spec assert_result!(String.t(), term()) :: :ok
  def assert_result!(method, result) do
    assert!(check_result(method, result))
  end

  # Validates a server notification. Raises `ExUnit.AssertionError` when
  # the message does not conform.
  #
  @spec assert_notification!(term()) :: :ok
  def assert_notification!(message) do
    assert!(check_notification(message))
  end

  # Validates a server request. Raises `ExUnit.AssertionError` when the
  # message does not conform.
  #
  @spec assert_server_request!(term()) :: :ok
  def assert_server_request!(message) do
    assert!(check_server_request(message))
  end

  # Validates an error response. Raises `ExUnit.AssertionError` when the
  # message does not conform.
  #
  @spec assert_error_response!(term()) :: :ok
  def assert_error_response!(message) do
    assert!(check_error_response(message))
  end

  # Builds the compiled schema root of one definition. The cache lives for
  # the whole test run: the suite never erases it.
  #
  @spec root(String.t()) :: JSV.Root.t()
  def root(name) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil -> build_and_cache(key, name)
      root -> root
    end
  end

  @spec assert!(:ok | [error()]) :: :ok
  defp assert!(:ok), do: :ok

  defp assert!(errors) when is_list(errors) do
    message =
      errors
      |> Enum.map_join("\n", fn %{definition: name, errors: list} ->
        "#{name}: #{format_errors(name, list)}"
      end)

    raise ExUnit.AssertionError, message: "message does not conform to the schema\n" <> message
  end

  @spec check_named(%{String.t() => String.t() | [String.t()]}, String.t(), term()) ::
          :ok | [error()]
  defp check_named(types, method, result) do
    case Map.fetch(types, method) do
      {:ok, names} -> check_any(List.wrap(names), result)
      :error -> :ok
    end
  end

  @spec check_any([String.t()], term()) :: :ok | [error()]
  defp check_any(names, value) do
    checked =
      for name <- names do
        {name, validate(name, value)}
      end

    if Enum.any?(checked, fn {_name, outcome} -> match?({:ok, _}, outcome) end) do
      :ok
    else
      for {name, {:error, list}} <- checked do
        %{definition: name, errors: list}
      end
    end
  end

  @spec validate(String.t(), term()) :: {:ok, term()} | {:error, [map()]}
  defp validate(name, value) do
    case JSV.validate(value, root(name)) do
      {:ok, _data} ->
        {:ok, value}

      {:error, error} ->
        %{details: details} =
          JSV.ErrorFormatter.normalize_error(error,
            min_error_level: JSV.ErrorFormatter.level_cause()
          )

        {:error, details}
    end
  end

  defp format_errors(name, list) do
    Enum.map_join(list, "\n", fn unit ->
      path = unit[:instanceLocation] || "#"

      Enum.map_join(unit[:errors] || [], "\n", fn e ->
        "#{name} #{path}: #{e.message}"
      end)
    end)
  end

  @spec build_and_cache({module(), String.t()}, String.t()) :: JSV.Root.t()
  defp build_and_cache(key, name) do
    schema = Map.put(@document, "$ref", "#/#{@defs_key}/#{name}")
    root = JSV.build!(schema)
    :persistent_term.put(key, root)
    root
  end
end
