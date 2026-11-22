defmodule OzMcp.Testing do
  @moduledoc """
  A client for the tests of an MCP server. It starts the server in the
  test, opens a session through `OzMcp.Router` and gives the answers as
  a client reads them.

      setup do
        {:ok, client} = OzMcp.Testing.start(MyApp.McpServer)
        %{client: client}
      end

      test "gives the weather", %{client: client} do
        assert {:ok, %{"content" => [%{"text" => "Sunny"}]}} =
                 OzMcp.Testing.call_tool(client, "weather", %{"city" => "Paris"})
      end

  The guide [Testing](guides/development/testing.md) shows the setup
  and each call.
  """

  alias OzMcp.Testing.Client

  @default_timeout 5_000
  @default_resource_url "http://localhost/mcp"
  @default_client_info %{"name" => "oz-mcp-testing", "version" => "1.0.0"}
  @client_keys [:token, :capabilities, :handle, :client_info, :timeout]

  @type client :: pid()
  @type error :: %{required(String.t()) => term()}
  @type kind :: :tools | :prompts | :resources | :resource_templates

  @doc """
  Starts the server `server` and one client of it, under the supervisor
  of the test. The options of the client are `:token` (a bearer token),
  `:capabilities` (the client capabilities of `initialize`, default
  `%{}`), `:handle` (a function of `method` and `params` that answers a
  request of the server with `{:ok, result}` or `{:error, error}`),
  `:client_info` and `:timeout` (milliseconds, default `5_000`). Every
  other option is an option of the instance.

  It runs in a test process only: it calls
  `ExUnit.Callbacks.start_supervised!/1`. A protected server needs a
  `:resource_url` unless its test verifier gives the audience
  `http://localhost/mcp`.
  """
  @spec start(module(), keyword()) :: {:ok, client()} | {:error, error()}
  def start(server, opts \\ []) do
    {given, instance_opts} = Keyword.split(opts, @client_keys)
    refuse_max_stream(instance_opts)

    name = Module.concat(server, "Testing#{System.unique_integer([:positive])}")
    instance_opts = instance_options(instance_opts, server, name)

    spec =
      Supervisor.child_spec({OzMcp, instance_opts},
        id: {OzMcp.Testing, name},
        restart: :temporary
      )

    _ = ExUnit.Callbacks.start_supervised!(spec)

    client_opts = [
      instance: name,
      router_opts: [instance: name],
      token: given[:token],
      handle: given[:handle],
      test_pid: self(),
      timeout: Keyword.get(given, :timeout, @default_timeout)
    ]

    spec =
      Supervisor.child_spec({Client, client_opts},
        id: {OzMcp.Testing, {:client, name}},
        restart: :temporary
      )

    client = ExUnit.Callbacks.start_supervised!(spec)

    case Client.initialize(client, initialize_params(given)) do
      {:ok, _result} -> {:ok, client}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Calls the tool `name` with `arguments`. The options are `:meta`, `:id`
  and `:timeout`.
  """
  @spec call_tool(client(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def call_tool(client, name, arguments \\ %{}, opts \\ []),
    do: request(client, "tools/call", %{"name" => name, "arguments" => arguments}, opts)

  @doc """
  Gets the prompt `name` with `arguments`. The options are `:meta`, `:id`
  and `:timeout`.
  """
  @spec get_prompt(client(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def get_prompt(client, name, arguments \\ %{}, opts \\ []),
    do: request(client, "prompts/get", %{"name" => name, "arguments" => arguments}, opts)

  @doc """
  Reads the resource `uri`. The options are `:meta`, `:id` and
  `:timeout`.
  """
  @spec read_resource(client(), String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def read_resource(client, uri, opts \\ []),
    do: request(client, "resources/read", %{"uri" => uri}, opts)

  @doc """
  Completes the reference `ref` with `argument`. The options are `:meta`,
  `:id` and `:timeout`.
  """
  @spec complete(client(), map(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def complete(client, ref, argument, opts \\ []),
    do: request(client, "completion/complete", %{"ref" => ref, "argument" => argument}, opts)

  @doc """
  Lists the entities of `kind`. The option `:cursor` continues a
  paginated list.
  """
  @spec list(client(), kind(), keyword()) :: {:ok, map()} | {:error, error()}
  def list(client, kind, opts \\ []) do
    params = if opts[:cursor], do: %{"cursor" => opts[:cursor]}, else: %{}
    request(client, list_method(kind), params, opts)
  end

  @doc """
  Sends the request `method` with `params` and gives its answer. The
  options are `:meta`, `:id` and `:timeout`.
  """
  @spec request(client(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def request(client, method, params \\ %{}, opts \\ []) do
    params = put_meta(params, opts[:meta])
    Client.request(client, method, params, opts)
  end

  @doc """
  Sends the notification `method` with `params`. The options are `:meta`
  and `:timeout`.
  """
  @spec notify(client(), String.t(), map(), keyword()) :: :ok | {:error, error()}
  def notify(client, method, params \\ %{}, opts \\ []) do
    params = put_meta(params, opts[:meta])
    Client.notify(client, method, params, opts)
  end

  @doc """
  The name of the instance of the client, for `OzMcp.Notify`:
  `OzMcp.Notify.resource_updated(OzMcp.Testing.instance(client), uri)`.
  """
  @spec instance(client()) :: atom()
  def instance(client), do: Client.instance(client)

  @doc """
  The result of the `initialize` of the client, with string keys, as the
  server sent it.
  """
  @spec initialize_result(client()) :: map()
  def initialize_result(client), do: Client.initialize_result(client)

  @doc """
  Ends the session of the client and stops it; the end of the test stops it without the `DELETE`.
  """
  @spec stop(client()) :: :ok
  def stop(client), do: Client.stop(client)

  defp initialize_params(given) do
    capabilities = Keyword.get(given, :capabilities, %{})
    client_info = Keyword.get(given, :client_info, @default_client_info)

    %{
      "protocolVersion" => OzMcp.Protocol.latest(),
      "capabilities" => capabilities,
      "clientInfo" => client_info
    }
  end

  defp instance_options(opts, server, name) do
    opts
    |> Keyword.put(:server, server)
    |> Keyword.put(:name, name)
    |> Keyword.put_new(:allowed_origins, [])
    |> maybe_resource_url(server)
  end

  defp maybe_resource_url(opts, server) do
    if protected?(server) and is_nil(Keyword.get(opts, :resource_url)),
      do: Keyword.put(opts, :resource_url, @default_resource_url),
      else: opts
  end

  defp protected?(server) do
    Code.ensure_loaded?(server) and function_exported?(server, :authorization, 0) and
      not is_nil(server.authorization())
  end

  defp refuse_max_stream(opts) do
    case Keyword.get(opts, :sse_max_stream_ms) do
      nil ->
        :ok

      _value ->
        raise ArgumentError,
              "OzMcp.Testing does not support the option :sse_max_stream_ms " <>
                "because it does not resume a stream"
    end
  end

  defp put_meta(params, nil), do: params
  defp put_meta(params, meta), do: Map.put(params, "_meta", meta)

  defp list_method(:tools), do: "tools/list"
  defp list_method(:prompts), do: "prompts/list"
  defp list_method(:resources), do: "resources/list"
  defp list_method(:resource_templates), do: "resources/templates/list"
end
