defmodule OzMcp.Context do
  @moduledoc """
  The context of one JSON-RPC message and the `ctx` map that the
  callbacks of the entities receive.

  The transport builds a `%OzMcp.Context{}` struct for each message:
  `OzMcp.Router` for HTTP, `OzMcp.Transport.Stdio` for stdio. The
  validation (OzMcp.Validate) fills the struct. The struct is
  internal.

  The framework passes the short `ctx` map to the callbacks `call/2`,
  `read/2`, `read/4`, `get/2`, `complete/4` and `roots_list_changed/1`:

  | Key | Value |
  |---|---|
  | `:instance` | the name of the instance that serves the request. It is always set. |
  | `:server` | the server module |
  | `:session_id` | the id of the session (`nil` before `initialize`) |
  | `:request_id` | the JSON-RPC id of the request (`nil` in a task) |
  | `:progress_token` | the `progressToken` of `_meta` of the request, or `nil` |
  | `:task_id` | the id of the task in a task runner, else `nil` |
  | `:client_capabilities` | the capabilities that the client declared in `initialize` |
  | `:principal` | an `OzMcp.Auth.Principal`, or `nil` when the server has no authorization |

  Read the capabilities of the client with `client_supports?/2`, or with
  the pure form `capability?/2`. `client_task_support?/2` tells whether
  the client runs a request as a task. The framework uses the other
  public functions. The application does not call them.

  The struct also carries the config of the instance (`config`). The
  router reads it one time for each request and puts it here, so the
  stages and the handler do not read the Registry again. The config is
  frozen at boot: a long stream or a stdio loop keeps the config of its
  start while the instance restarts with the same options.
  """

  alias OzMcp.Context.Error

  # The capability of the client for each method that it can run as a task.
  #
  @task_capabilities %{
    "sampling/createMessage" => [:tasks, :requests, :sampling, :createMessage],
    "elicitation/create" => [:tasks, :requests, :elicitation, :create]
  }

  @type transport :: :http_streamable | :stdio

  @type mode :: :http | :rpc

  @type rpc_kind :: OzMcp.Utils.JsonRpc.kind() | nil

  @type ctx :: %{
          instance: OzMcp.Instance.t(),
          server: module(),
          session_id: String.t() | nil,
          request_id: integer() | String.t() | nil,
          progress_token: term() | nil,
          task_id: String.t() | nil,
          client_capabilities: map(),
          principal: OzMcp.Auth.Principal.t() | nil
        }

  @type t :: %__MODULE__{
          transport: transport(),
          mode: mode(),
          instance: OzMcp.Instance.t(),
          config: OzMcp.Instance.Config.t() | nil,
          server: module(),
          conn: %Plug.Conn{} | nil,
          session_id: String.t() | nil,
          rpc: map() | nil,
          rpc_id: OzMcp.Utils.JsonRpc.id(),
          rpc_kind: rpc_kind(),
          rpc_method: String.t() | nil,
          rpc_params: map() | nil,
          rpc_response: {:ok, map()} | {:error, map()} | {:orphan_error, map()} | nil,
          negotiated_protocol_version: String.t() | nil,
          client_info: map() | nil,
          client_capabilities: map() | nil,
          session_initialized: boolean() | nil,
          log_level: atom() | nil,
          bound: OzMcp.Pipeline.Bound.t() | nil,
          completion_ref: String.t() | nil,
          completion_argument: map() | nil,
          completion_context: map() | nil,
          progress_token: term() | nil,
          task_id: String.t() | nil,
          tasks_cursor: String.t() | nil,
          principal: OzMcp.Auth.Principal.t() | nil,
          error: %Error{} | nil
        }

  defstruct transport: :http_streamable,
            mode: :rpc,
            instance: nil,
            config: nil,
            server: nil,
            conn: nil,
            session_id: nil,
            rpc: nil,
            rpc_id: nil,
            rpc_kind: nil,
            rpc_method: nil,
            rpc_params: nil,
            rpc_response: nil,
            negotiated_protocol_version: nil,
            client_info: nil,
            client_capabilities: %{},
            session_initialized: nil,
            log_level: nil,
            bound: nil,
            completion_ref: nil,
            completion_argument: nil,
            completion_context: nil,
            progress_token: nil,
            task_id: nil,
            tasks_cursor: nil,
            principal: nil,
            error: nil

  @doc false
  @spec new(OzMcp.Instance.t(), transport(), mode(), OzMcp.Instance.Config.t() | nil) ::
          %__MODULE__{}
  def new(instance, transport, mode, config \\ nil) do
    if transport not in [:http_streamable, :stdio], do: raise("invalid context transport")
    if mode not in [:http, :rpc], do: raise("invalid context mode")

    %__MODULE__{
      transport: transport,
      mode: mode,
      instance: instance,
      config: config,
      server: server_of(instance, config)
    }
  end

  defp server_of(_instance, %{server: server}), do: server
  defp server_of(instance, nil), do: OzMcp.Instance.server_module(instance)

  @doc false
  @spec put_http_conn(%__MODULE__{}, Plug.Conn.t()) :: %__MODULE__{}
  def put_http_conn(struct, conn) do
    struct
    |> Map.put(:conn, conn)
    |> put_rpc(conn.body_params)
  end

  @doc false
  @spec put_rpc(%__MODULE__{}, map()) :: %__MODULE__{}
  def put_rpc(struct, rpc) do
    Map.put(struct, :rpc, rpc)
  end

  # True when the message of the context is a request with a valid id.
  #
  # A `nil` `rpc_kind` means that the JSON-RPC validation did not run (for
  # example a `GET` or a `DELETE`), so the answer is `false`.
  #
  @doc false
  @spec request?(t()) :: boolean()
  def request?(%__MODULE__{rpc_kind: :request}), do: true
  def request?(%__MODULE__{}), do: false

  @doc false
  @spec put_error(%__MODULE__{}, atom(), any | nil, [Error.header()]) :: %__MODULE__{}
  def put_error(struct, code, data \\ nil, headers \\ []),
    do: Map.put(struct, :error, Error.new(code, data, headers))

  # Convert the context to the short context that the callbacks receive:
  # `tools/call`, `resources/read`, `resources/templates/list`,
  # `prompts/get`, `completion/complete`, `roots_list_changed/1`.
  #
  # `principal` is the authenticated caller of the request (`nil` when the
  # server has no authorization). It never holds the raw token. Keep the
  # `claims` of a principal small: a task keeps a copy of it for its whole
  # life.
  #
  @doc false
  @spec to_ctx(%__MODULE__{}) :: ctx()
  def to_ctx(%__MODULE__{} = context) do
    %{
      instance: context.instance,
      server: context.server,
      session_id: context.session_id,
      request_id: context.rpc_id,
      progress_token: context.progress_token,
      task_id: nil,
      client_capabilities: context.client_capabilities || %{},
      principal: context.principal
    }
  end

  @doc """
  True when the client declared the capability during `initialize`.

  `capability` is an atom or a string (`:sampling`, `"roots"`), or a list of
  them for a nested member (`[:sampling, :tools]`). A capability the client
  declared with an empty object (`"elicitation": {}`) is supported.

  Accepts the short context handed to the user callbacks: the capabilities
  are part of it (`ctx.client_capabilities`, fixed by `initialize`), so this
  is a lookup in a map. A hand-built ctx without them (`:client_capabilities`
  key missing) is answered from the session of `:instance` and `:session_id`,
  so the result is `false` when the session does not exist any more, or when
  the ctx has no `:instance`.
  """
  @spec client_supports?(ctx() | t(), atom() | String.t() | [atom() | String.t()]) :: boolean()
  def client_supports?(ctx, capability) do
    case fetch_client_capabilities(ctx) do
      {:ok, capabilities} -> capability?(capabilities, capability)
      :error -> false
    end
  end

  # The declared capabilities of the client of a ctx: from the ctx itself,
  # else (a ctx built by hand) from the session of `:instance` and
  # `:session_id`. A ctx with no `:instance` reads no session and gives
  # `:error`.
  #
  @doc false
  @spec fetch_client_capabilities(map()) :: {:ok, map()} | :error
  def fetch_client_capabilities(%{client_capabilities: capabilities}) when is_map(capabilities),
    do: {:ok, capabilities}

  def fetch_client_capabilities(%{instance: instance, session_id: session_id})
      when is_binary(session_id) do
    case OzMcp.Sessions.client_capabilities(instance, session_id) do
      {:ok, capabilities} -> {:ok, capabilities}
      _ -> :error
    end
  end

  def fetch_client_capabilities(_ctx), do: :error

  @doc """
  Pure form of `client_supports?/2`: looks the capability up in a map of
  declared client capabilities (JSON object with string keys).
  """
  @spec capability?(term(), atom() | String.t() | [atom() | String.t()]) :: boolean()
  def capability?(capabilities, path) when is_list(path) do
    Enum.reduce_while(path, capabilities, fn key, current ->
      case member(current, key) do
        %{} = next -> {:cont, next}
        _ -> {:halt, false}
      end
    end)
    |> is_map()
  end

  def capability?(capabilities, capability), do: capability?(capabilities, [capability])

  @doc """
  `true` when the client runs the request `method` as a task:
  `tasks.requests.sampling.createMessage` or
  `tasks.requests.elicitation.create`.

  A method that the client cannot run as a task gives `false`. Accepts the
  same contexts as `client_supports?/2`.
  """
  @spec client_task_support?(ctx() | t(), String.t()) :: boolean()
  def client_task_support?(ctx, method) do
    case fetch_client_capabilities(ctx) do
      {:ok, capabilities} -> task_capability?(capabilities, method)
      :error -> false
    end
  end

  # The pure form, for a map of capabilities (a stream of a task has no ctx).
  #
  @doc false
  @spec task_capability?(term(), String.t()) :: boolean()
  def task_capability?(capabilities, method) do
    case Map.fetch(@task_capabilities, method) do
      {:ok, path} -> capability?(capabilities, path)
      :error -> false
    end
  end

  defp member(%{} = map, key), do: Map.get(map, to_string(key))
  defp member(_other, _key), do: nil
end
