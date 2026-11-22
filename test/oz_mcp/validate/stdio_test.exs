defmodule OzMcp.Validate.StdioTest do
  use ExUnit.Case, async: true

  alias OzMcp.{Context, Sessions, Validate}
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default

  @server Module.concat(@server_module, __MODULE__)
  setup do
    Utils.start_instance(@server_module, name: @server)

    :ok
  end

  defp context(overrides) do
    Context.new(@server, :stdio, :rpc)
    |> Map.put(:session_id, Keyword.get(overrides, :session_id))
    |> Map.put(:rpc_id, Keyword.get(overrides, :rpc_id))
    |> Map.put(:rpc_method, Keyword.get(overrides, :rpc_method))
    |> Map.put(:rpc_params, Keyword.get(overrides, :rpc_params))
    |> Map.put(:rpc_response, Keyword.get(overrides, :rpc_response))
    |> Map.put(:negotiated_protocol_version, Keyword.get(overrides, :negotiated_protocol_version))
    |> Map.put(:client_info, Keyword.get(overrides, :client_info))
    |> Map.put(:client_capabilities, Keyword.get(overrides, :client_capabilities))
  end

  defp rpc_context(rpc, overrides \\ []) do
    Context.new(@server, :stdio, :rpc)
    |> Context.put_rpc(rpc)
    |> Map.put(:session_id, Keyword.get(overrides, :session_id))
  end

  # The answer of a pipeline stage: the context it carries.
  #
  defp plain({:cont, context}), do: context
  defp plain({:halt, context}), do: context

  @initialize_params %{
    "protocolVersion" => "2025-11-25",
    "clientInfo" => %{"name" => "stdio-client", "version" => "1.0.0"},
    "capabilities" => %{"roots" => %{}}
  }

  describe "session_id/1" do
    test "initialize passes and creates no session: the handler creates it" do
      size_before = Utils.session_count(@server)

      context =
        rpc_context(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => @initialize_params
        })

      result = plain(Validate.stdio(context))

      assert is_nil(result.error)
      assert is_nil(result.session_id)
      assert result.negotiated_protocol_version == "2025-11-25"
      assert result.client_capabilities == %{"roots" => %{}}
      assert Utils.session_count(@server) == size_before
    end

    test "a second initialize gives :rpc_already_initialized" do
      result =
        plain(
          Validate.Stdio.session_id(
            context(rpc_method: "initialize", session_id: Utils.generate_session_id())
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :rpc_already_initialized
    end

    test "ping with no session passes" do
      result = plain(Validate.Stdio.session_id(context(rpc_method: "ping", rpc_id: 1)))

      assert is_nil(result.error)
      assert is_nil(result.session_id)
    end

    test "an answer of the client with no session passes" do
      result =
        plain(
          Validate.Stdio.session_id(context(rpc_id: 7, rpc_response: {:ok, %{"content" => []}}))
        )

      assert is_nil(result.error)
      assert is_nil(result.session_id)
    end

    test "a request with no session gives :rpc_session_waiting_initialization" do
      result = plain(Validate.Stdio.session_id(context(rpc_method: "tools/list", rpc_id: 2)))

      refute is_nil(result.error)
      assert result.error.code == :rpc_session_waiting_initialization
    end
  end

  describe "session/1" do
    test "a request for a session that is not initialized gives :rpc_session_waiting_initialization" do
      session_id = Utils.create_session(@server)

      result =
        plain(
          Validate.Stdio.session(
            context(rpc_method: "tools/list", rpc_id: 3, session_id: session_id)
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :rpc_session_waiting_initialization
    end

    test "a request for an initialized session passes and carries the client capabilities" do
      session_id =
        Utils.create_session(@server,
          initialized: true,
          client_capabilities: %{"roots" => %{}}
        )

      result =
        plain(
          Validate.Stdio.session(
            context(rpc_method: "tools/list", rpc_id: 4, session_id: session_id)
          )
        )

      assert is_nil(result.error)
      assert result.client_capabilities == %{"roots" => %{}}
    end

    test "notifications/initialized passes for a session that is not initialized" do
      session_id = Utils.create_session(@server)

      result =
        plain(
          Validate.Stdio.session(
            context(rpc_method: "notifications/initialized", session_id: session_id)
          )
        )

      assert is_nil(result.error)
    end

    test "notifications/initialized passes for an already initialized session" do
      session_id = Utils.create_session(@server, initialized: true)

      result =
        plain(
          Validate.Stdio.session(
            context(rpc_method: "notifications/initialized", session_id: session_id)
          )
        )

      assert is_nil(result.error)
      assert result.session_initialized == true
    end

    test "a request with a session id the store does not know gives :http_invalid_session" do
      result =
        plain(
          Validate.Stdio.session(
            context(
              rpc_method: "tools/list",
              rpc_id: 5,
              session_id: Utils.generate_session_id()
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_invalid_session
    end

    test "a context with no connection and a session version in the store does not raise" do
      {:ok, session_id} =
        Sessions.start(@server,
          protocol_version: "2025-11-25",
          client_info: nil,
          client_capabilities: %{}
        )

      :ok = Sessions.set_initialized(@server, session_id)

      result =
        plain(
          Validate.Stdio.session(
            context(rpc_method: "tools/list", rpc_id: 6, session_id: session_id)
          )
        )

      assert is_nil(result.error)
    end
  end

  describe "stdio/1" do
    test "runs the JSON-RPC step: an unknown tool keeps its error" do
      context =
        rpc_context(
          %{
            "jsonrpc" => "2.0",
            "id" => 9,
            "method" => "tools/call",
            "params" => %{"name" => "no_such_tool", "arguments" => %{}}
          },
          session_id: Utils.create_session(@server, initialized: true)
        )

      {:cont, context} = Validate.stdio(context)
      result = plain(Validate.stdio_bind(context))

      refute is_nil(result.error)
      assert result.error.code == :rpc_tool_not_found
    end
  end
end
