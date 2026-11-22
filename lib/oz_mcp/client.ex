defmodule OzMcp.Client do
  @moduledoc """
  What a callback can ask of the client: input from the user (elicitation),
  a model completion (sampling) and the roots of the client.

  The functions block the calling process until the client answers. They
  run inside a callback (`tool.call/2`, `resource.read/2`, `prompt.get/2`, a
  task tool) and take its `ctx`. They are built on `OzMcp.Outbound.request/4`:
  the client must have declared the capability (`elicitation`, `sampling`,
  `roots`), else nothing is sent and the result is
  `{:error, :capability_not_supported}`. Every error of
  `OzMcp.Outbound` is possible; the options `:timeout` and
  `:wait_for_stream` are passed to it.

  ## Invalid arguments

  `elicit/3`, `sample/3` and `url_elicitation_required/2` build their params
  with the structs of `OzMcp.Structs` and raise `ArgumentError` for invalid
  arguments (a missing `:message` or `:max_tokens`, a schema that is not
  flat, a URL with credentials, tool use messages out of order). This is for
  a programmer error. Inside a callback the raise is caught by the framework:
  the client gets the generic `-32603` error and the log has the cause.

  ## Waiting time

  The client has a limited time to answer and a call that waits longer ends
  with `{:error, :timeout}` (the client is told to cancel the request). The
  default depends on who answers (a person, a model, or `list_roots/2`);
  the `:timeout` option of a call overrides it. The guide about the requests
  to the client gives the options and the default of each method.

  ## Elicitation

  `elicit/3` asks the user for input. With a schema it is a **form**: the
  client shows the fields and returns the values. With a URL it is a **URL**
  interaction: the client sends the user to a web page and the data never
  passes through the client (use it for credentials and authorizations).

      schema =
        %ElicitationSchema{}
        |> ElicitationSchema.property("name", %StringSchema{} |> StringSchema.title("Name"))
        |> ElicitationSchema.required(["name"])

      case OzMcp.Client.elicit(ctx, schema, message: "Who are you?") do
        {:ok, %{action: :accept, content: %{"name" => name}}} -> name
        {:ok, %{action: action}} when action in [:decline, :cancel] -> nil
        {:error, reason} -> reason
      end

  A form the client did not declare is not sent (an empty `elicitation: {}`
  means form only). The content of an accepted form is validated against the
  schema (`validate: false` turns it off). The guide about the requests to
  the client gives the rules of the validation and of the defaults.

  A callback that needs a URL interaction before it can run at all returns
  the error of `url_elicitation_required/2`.

  ## Sampling

  `sample/3` asks the client to run a model on a conversation. `max_tokens`
  is required. Tools (`tools:`) and `tool_choice:` need the client capability
  `sampling.tools`; `include_context:` other than `:none` needs
  `sampling.context`.

      messages = [OzMcp.Structs.SamplingMessage.user("Summarize this text: ...")]

      {:ok, %{content: [%{"type" => "text", "text" => text}]}} =
        OzMcp.Client.sample(ctx, messages, max_tokens: 300)

  ## Roots

  `list_roots/2` returns the roots the client exposes. A server that wants to
  know when they change defines `roots_list_changed/1` (see
  `OzMcp.Config.Server`).

  ## Tasks of the client

  `sample/3` and `elicit/3` can run the request as a task of the client:
  pass `task: true` or `task: %{ttl: milliseconds}`. The client answers at
  once with a task, the server polls `tasks/get` and reads the final result
  with `tasks/result`. Use it for a long sampling or a long human input: one
  request is not held open. The option needs the runtime option
  `client_tasks` (default `false`, experimental) and a client without the
  task capability gets a plain request unless `task_required: true`. The
  guide about the requests to the client describes the flow and its errors.

  ## In a task

  A callback that runs as a task (`ctx.task_id` is set) can use all of these
  functions: the request travels on the `tasks/result` stream of the task
  with the `io.modelcontextprotocol/related-task` meta and the task is
  `input_required` while it waits. If the client does not call
  `tasks/result`, the request ends with `{:error, :timeout}`.

  A task of the client (`task:`) is a different thing from the task of the
  server: the server task stays `working` while its polls can travel on a
  `tasks/result` stream.
  """

  alias OzMcp.{Context, Outbound}
  alias OzMcp.Structs.{CreateMessageRequestParams, ElicitationSchema}
  alias OzMcp.Structs.{ElicitRequestFormParams, ElicitRequestURLParams, SamplingMessage}
  alias OzMcp.Utils.{Error, Generator, JsonSchemaValidator}

  @url_elicitation_required_code -32042
  @request_opts [:timeout, :wait_for_stream]
  @actions %{"accept" => :accept, "decline" => :decline, "cancel" => :cancel}

  @type ctx :: Outbound.ctx()

  @type elicit_result :: %{
          required(:action) => :accept | :decline | :cancel,
          required(:content) => map() | nil,
          optional(:elicitation_id) => String.t()
        }

  @type sample_result :: %{
          role: String.t(),
          content: [map()],
          model: String.t(),
          stop_reason: String.t() | nil
        }

  # ---- Elicitation ----

  @doc """
  Asks the user for input. `schema_or_url` is an
  `OzMcp.Structs.ElicitationSchema` struct or a map (form mode), or a URL
  string (URL mode).

  Options:

    * `:message` (required) — what the user sees, with the reason for the
      request.
    * `:elicitation_id` — URL mode only: the identifier of the interaction
      (generated by default). It is part of the result.
    * `:validate` — form mode only: validate the content against the schema
      (default `true`).
    * `:_meta` — a `_meta` map for the request.
    * `:task` — run the request as a task of the client: `true` or
      `%{ttl: milliseconds}`. Needs the runtime option `client_tasks`
      (experimental) and the client capability
      `tasks.requests.elicitation.create`.
    * `:task_required` and `:poll_interval` — the same as in
      `OzMcp.Outbound.request_task/4`.
    * `:timeout`, `:wait_for_stream` — see `OzMcp.Outbound.request/4`.

  Returns `{:ok, %{action: action, content: content}}`. `action` is
  `:accept`, `:decline` or `:cancel`; `content` is the map of the values
  (string keys) for an accepted form, `nil` otherwise. In URL mode `:accept`
  means the user agreed to open the URL, not that the interaction is done.
  A client task gives the errors of `OzMcp.Outbound.request_task/4`:
  `{:error, {:client_task_cancelled, task_id}}` and
  `{:error, {:invalid_response, result}}` in addition to the plain ones.
  """
  @spec elicit(ctx(), ElicitationSchema.t() | map() | String.t(), keyword()) ::
          {:ok, elicit_result()} | {:error, term()}
  def elicit(ctx, schema_or_url, opts \\ [])

  def elicit(ctx, url, opts) when is_binary(url) do
    elicitation_id = Keyword.get_lazy(opts, :elicitation_id, &Generator.elicitation_id/0)

    params =
      %ElicitRequestURLParams{}
      |> ElicitRequestURLParams.message(message!(opts))
      |> ElicitRequestURLParams.url(url)
      |> ElicitRequestURLParams.elicitation_id(elicitation_id)
      |> maybe(opts, :_meta, &ElicitRequestURLParams._meta/2)
      |> ElicitRequestURLParams.build()

    with {:ok, result} <- request(ctx, "elicitation/create", params, opts),
         {:ok, parsed} <- parse_elicit(result) do
      {:ok, Map.put(parsed, :elicitation_id, elicitation_id)}
    end
  end

  def elicit(ctx, schema, opts) do
    params =
      %ElicitRequestFormParams{}
      |> ElicitRequestFormParams.message(message!(opts))
      |> ElicitRequestFormParams.requested_schema(schema)
      |> maybe(opts, :_meta, &ElicitRequestFormParams._meta/2)
      |> ElicitRequestFormParams.build()

    with {:ok, result} <- request(ctx, "elicitation/create", params, opts),
         {:ok, parsed} <- parse_elicit(result) do
      validate_content(parsed, params.requestedSchema, Keyword.get(opts, :validate, true))
    end
  end

  @doc """
  Builds the error of a request that cannot run before the user finishes a
  URL interaction (JSON-RPC error `-32042`). A callback returns it:

      def call(ctx, params) do
        {:error,
         OzMcp.Client.url_elicitation_required([
           %{url: "https://example.com/connect", message: "Connect your account"}
         ])}
      end

  Each elicitation is a map with `:url` and `:message` and optionally
  `:elicitation_id` (generated by default). The client opens the URLs and
  retries the request when the interactions are done.
  """
  @spec url_elicitation_required([map()], String.t()) :: Error.t()
  def url_elicitation_required(elicitations, message \\ "This request requires more information.")
      when is_list(elicitations) and elicitations != [] do
    elicitations =
      Enum.map(elicitations, fn elicitation ->
        params =
          %ElicitRequestURLParams{}
          |> ElicitRequestURLParams.message(fetch!(elicitation, :message))
          |> ElicitRequestURLParams.url(fetch!(elicitation, :url))
          |> ElicitRequestURLParams.elicitation_id(
            get(elicitation, :elicitation_id) || Generator.elicitation_id()
          )
          |> ElicitRequestURLParams.build()

        Map.new(params, fn {key, value} -> {to_string(key), value} end)
      end)

    Error.new(@url_elicitation_required_code, message, %{"elicitations" => elicitations})
  end

  # ---- Sampling ----

  @doc """
  Asks the client to complete a conversation with a model.

  `messages` is a list of `OzMcp.Structs.SamplingMessage` structs or maps.

  Options:

    * `:max_tokens` (required)
    * `:system_prompt`, `:temperature`, `:stop_sequences`, `:metadata`
    * `:model_preferences` — a `OzMcp.Structs.ModelPreferences` struct or map
    * `:include_context` — `:none`, `:this_server` or `:all_servers`
    * `:tools` — a list of `OzMcp.Structs.Tool` structs or maps
    * `:tool_choice` — `:auto`, `:required`, `:none` or a
      `OzMcp.Structs.ToolChoice`
    * `:task` — run the request as a task of the client: `true` or
      `%{ttl: milliseconds}`. Needs the runtime option `client_tasks`
      (experimental) and the client capability
      `tasks.requests.sampling.createMessage`.
    * `:task_required` and `:poll_interval` — the same as in
      `OzMcp.Outbound.request_task/4`.
    * `:_meta`, `:timeout`, `:wait_for_stream`

  Returns `{:ok, result}` with `role`, `content` (always a list of blocks
  with string keys), `model` and `stop_reason` (`"endTurn"`, `"toolUse"`,
  `"maxTokens"`, ... or `nil`). When `stop_reason` is `"toolUse"` the content
  has `tool_use` blocks: run the tools and sample again with their results.
  A client task gives the errors of `OzMcp.Outbound.request_task/4`:
  `{:error, {:client_task_cancelled, task_id}}` and
  `{:error, {:invalid_response, result}}` in addition to the plain ones.
  """
  @spec sample(ctx(), [SamplingMessage.t() | map()], keyword()) ::
          {:ok, sample_result()} | {:error, term()}
  def sample(ctx, messages, opts \\ []) do
    params =
      %CreateMessageRequestParams{}
      |> CreateMessageRequestParams.messages(messages)
      |> maybe(opts, :max_tokens, &CreateMessageRequestParams.max_tokens/2)
      |> maybe(opts, :system_prompt, &CreateMessageRequestParams.system_prompt/2)
      |> maybe(opts, :temperature, &CreateMessageRequestParams.temperature/2)
      |> maybe(opts, :stop_sequences, &CreateMessageRequestParams.stop_sequences/2)
      |> maybe(opts, :metadata, &CreateMessageRequestParams.metadata/2)
      |> maybe(opts, :model_preferences, &CreateMessageRequestParams.model_preferences/2)
      |> maybe(opts, :include_context, &CreateMessageRequestParams.include_context/2)
      |> maybe(opts, :tools, &CreateMessageRequestParams.tools/2)
      |> maybe(opts, :tool_choice, &CreateMessageRequestParams.tool_choice/2)
      |> maybe(opts, :_meta, &CreateMessageRequestParams._meta/2)
      |> CreateMessageRequestParams.build()

    with {:ok, result} <- request(ctx, "sampling/createMessage", params, opts) do
      parse_sample(result, Map.has_key?(params, :tools))
    end
  end

  # ---- Roots ----

  @doc """
  Asks the client for its roots.

  Returns `{:ok, roots}`: a list of maps with the string keys `"uri"` (a
  `file://` URI) and, optionally, `"name"`.
  """
  @spec list_roots(ctx(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_roots(ctx, opts \\ []) do
    with {:ok, result} <-
           Outbound.request(ctx, "roots/list", nil, Keyword.take(opts, @request_opts)) do
      parse_roots(result)
    end
  end

  # ---- Internals ----

  defp request(ctx, method, params, opts) do
    request_opts = Keyword.take(opts, @request_opts)

    case task_mode(ctx, method, opts) do
      :plain -> Outbound.request(ctx, method, params, request_opts)
      {:task, task_opts} -> Outbound.request_task(ctx, method, params, task_opts ++ request_opts)
      :unsupported -> {:error, :capability_not_supported}
    end
  end

  defp task_mode(ctx, method, opts) do
    case Keyword.get(opts, :task) do
      nil ->
        :plain

      task ->
        task_opts = task_opts(task, opts)

        cond do
          not Outbound.client_tasks?(ctx) or Context.client_task_support?(ctx, method) ->
            {:task, task_opts}

          Keyword.get(opts, :task_required, false) ->
            :unsupported

          true ->
            :plain
        end
    end
  end

  defp task_opts(task, opts), do: ttl_opts(task) ++ Keyword.take(opts, [:poll_interval])

  defp ttl_opts(true), do: []
  defp ttl_opts(%{ttl: ttl}) when is_integer(ttl) and ttl > 0, do: [ttl: ttl]
  defp ttl_opts(other), do: raise(ArgumentError, "invalid :task option: #{inspect(other)}")

  defp message!(opts) do
    case Keyword.fetch(opts, :message) do
      {:ok, message} -> message
      :error -> raise ArgumentError, "the :message option is required"
    end
  end

  defp maybe(struct, opts, key, setter) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> setter.(struct, value)
      :error -> struct
    end
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp fetch!(map, key) do
    case get(map, key) do
      nil -> raise ArgumentError, "an elicitation needs #{inspect(key)}"
      value -> value
    end
  end

  # ---- Answers of the client ----

  defp parse_elicit(%{"action" => action} = result) when is_map_key(@actions, action) do
    action = Map.fetch!(@actions, action)
    content = Map.get(result, "content")

    cond do
      action != :accept -> {:ok, %{action: action, content: nil}}
      is_map(content) or is_nil(content) -> {:ok, %{action: :accept, content: content}}
      true -> {:error, {:invalid_response, result}}
    end
  end

  defp parse_elicit(result), do: {:error, {:invalid_response, result}}

  defp validate_content(%{action: :accept} = parsed, schema, true) do
    case JsonSchemaValidator.validate_schema(schema, parsed.content || %{}) do
      {:ok, _content} -> {:ok, parsed}
      {:error, :invalid_schema} -> {:error, :invalid_schema}
      {:error, messages} -> {:error, {:invalid_content, messages}}
    end
  end

  defp validate_content(parsed, _schema, _validate?), do: {:ok, parsed}

  defp parse_sample(%{"role" => role, "content" => content, "model" => model} = result, tools?)
       when role in ["user", "assistant"] and is_binary(model) and
              (is_map(content) or is_list(content)) do
    blocks = List.wrap(content)

    if Enum.all?(blocks, &valid_block?(&1, tools?)) do
      {:ok,
       %{role: role, content: blocks, model: model, stop_reason: Map.get(result, "stopReason")}}
    else
      {:error, {:invalid_response, result}}
    end
  end

  defp parse_sample(result, _tools?), do: {:error, {:invalid_response, result}}

  # A `tool_use` block answers a request that offered tools.
  #
  defp valid_block?(%{"type" => "tool_use"}, tools?), do: tools?
  defp valid_block?(%{"type" => type}, _tools?), do: is_binary(type)
  defp valid_block?(_block, _tools?), do: false

  defp parse_roots(%{"roots" => roots} = result) when is_list(roots) do
    if Enum.all?(roots, &valid_root?/1),
      do: {:ok, roots},
      else: {:error, {:invalid_response, result}}
  end

  defp parse_roots(result), do: {:error, {:invalid_response, result}}

  defp valid_root?(%{"uri" => "file://" <> _rest} = root) do
    is_nil(Map.get(root, "name")) or is_binary(Map.get(root, "name"))
  end

  defp valid_root?(_root), do: false
end
