defmodule OzMcp.InstanceRoutingTest do
  #
  # Each test starts its own two instances with unique names, so the
  # tests run in parallel.
  #
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias OzMcp.{Context, Session, Sessions}
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.Default

  setup do
    suffix = System.unique_integer([:positive])
    a = Module.concat(@server, "A#{suffix}")
    b = Module.concat(@server, "B#{suffix}")

    start_supervised!({OzMcp, server: @server, name: a, allowed_origins: []}, id: :a)
    start_supervised!({OzMcp, server: @server, name: b, allowed_origins: []}, id: :b)

    %{a: a, b: b}
  end

  defp initialize(instance) do
    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "t", "version" => "1"}
        }
      })

    conn =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> OzMcp.Router.call(OzMcp.Router.init(instance: instance, allowed_origins: []))

    assert conn.status == 200
    [session_id] = get_resp_header(conn, "mcp-session-id")
    session_id
  end

  describe "Router" do
    test "init/1 uses the server module as the default instance" do
      assert OzMcp.Router.init(server: @server)[:instance] == @server
    end

    test "an explicit instance serves the sessions of that instance only", %{a: a, b: b} do
      session_id = initialize(a)

      assert {:ok, _} = Sessions.state(a, session_id)
      assert Sessions.state(b, session_id) == {:error, :no_session}
      assert [{^session_id, _}] = Utils.sessions(a)
      assert Utils.sessions(b) == []
    end
  end

  describe "Auth.Metadata" do
    test "init/1 accepts the option :instance", %{a: a} do
      assert OzMcp.Auth.Metadata.init(instance: a, server: @server) == a
      assert OzMcp.Auth.Metadata.init(server: @server) == @server
    end
  end

  describe "Context" do
    test "new/3 gets the instance and reads the server module from its config", %{a: a} do
      context = Context.new(a, :http_streamable, :rpc)

      assert context.instance == a
      assert context.server == @server
      assert %{instance: ^a, server: @server} = Context.to_ctx(context)
    end
  end

  describe "Notify" do
    test "a notification of an instance reaches only the sessions of that instance", %{
      a: a,
      b: b
    } do
      {:ok, session_a} = Sessions.start(a)
      :ok = Sessions.set_initialized(a, session_a)
      {:ok, _} = Session.open_stream(a, session_a, :get, self(), nil)

      other = spawn_link(fn -> Process.sleep(:infinity) end)
      {:ok, session_b} = Sessions.start(b)
      :ok = Sessions.set_initialized(b, session_b)
      {:ok, _} = Session.open_stream(b, session_b, :get, other, nil)

      assert :ok = Support.Helpers.Broadcast.notify_all(a)

      expected = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}
      {_, ^expected} = Utils.receive_event(5_000)

      assert {:ok, [_ | _]} = SessionProbe.events_after(a, session_a, "")
      assert {:ok, events_b} = SessionProbe.events_after(b, session_b, "")
      refute Enum.any?(events_b, fn {_id, data} -> data =~ "list_changed" end)
    end

    test "a ctx with an instance routes the call to that instance", %{a: a} do
      {:ok, session_a} = Sessions.start(a)
      ctx = %{instance: a, server: @server, session_id: session_a, progress_token: nil}

      assert {:ok, %{}} = Sessions.state(ctx.instance, session_a)
    end
  end
end
