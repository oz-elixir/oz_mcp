defmodule OzMcp.Tasks.ScopesTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias OzMcp.Auth.Principal
  alias OzMcp.Tasks
  alias OzMcp.Tasks.EtsStore
  alias OzMcp.Tasks.Records
  alias Support.Helpers.Utils
  alias Support.Servers

  @resource_url "https://mcp.example.com/mcp"
  @metadata_url "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"

  setup do
    tag = "S#{System.unique_integer([:positive])}"

    Process.put(
      :scopes_instances,
      {Module.concat(Servers.Scoped, tag), Module.concat(Servers.TasksTest, tag)}
    )

    Utils.start_instance(Servers.Scoped, name: server(), resource_url: @resource_url)
    Utils.start_instance(Servers.TasksTest, name: open())
    :ok
  end

  # The names of the instances of the test: the setup gives each one a
  # name of its own, so the tests of the file (and of the other files) run
  # apart.
  #
  defp server, do: elem(Process.get(:scopes_instances), 0)
  defp open, do: elem(Process.get(:scopes_instances), 1)

  defp rpc(id, method, params, token, session_id) do
    body =
      %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
      |> :json.encode()
      |> IO.iodata_to_binary()

    conn =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("authorization", "Bearer #{token}")

    conn = if session_id, do: put_req_header(conn, "mcp-session-id", session_id), else: conn

    OzMcp.Router.call(conn, OzMcp.Router.init(server: server(), allowed_origins: []))
  end

  defp session(token) do
    conn =
      rpc(
        1,
        "initialize",
        %{
          "protocolVersion" => "2025-11-25",
          "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"}
        },
        token,
        nil
      )

    assert [session_id] = get_resp_header(conn, "mcp-session-id")

    notification =
      %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}}
      |> :json.encode()
      |> IO.iodata_to_binary()

    conn =
      conn(:post, "/", notification)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("mcp-session-id", session_id)
      |> then(&OzMcp.Router.call(&1, OzMcp.Router.init(server: server(), allowed_origins: [])))

    assert conn.status == 202
    session_id
  end

  defp create_write_task(session_id) do
    conn =
      rpc(
        2,
        "tools/call",
        %{"name" => "write_file", "arguments" => %{"path" => "a"}, "task" => %{}},
        "alice-admin",
        session_id
      )

    assert conn.status == 200
    :json.decode(conn.resp_body)["result"]["task"]["taskId"]
  end

  defp alice do
    Principal.new!(issuer: "https://issuer.test", subject: "alice", scopes: ["files:read"])
  end

  defp put_working(owner_key, required_scopes) do
    now = DateTime.utc_now()

    record = %EtsStore{
      task_id: OzMcp.Utils.Generator.task_id(),
      session_id: "s",
      owner_key: owner_key,
      seq: System.unique_integer([:monotonic, :positive]),
      status: :working,
      created_at: now,
      last_updated_at: now,
      required_scopes: required_scopes
    }

    :ok = Records.put(EtsStore, server(), record)
    record
  end

  describe "the scopes of a task" do
    test "the record keeps the scopes of the tool" do
      session_id = session("alice-admin")
      task_id = create_write_task(session_id)

      assert {:ok, %{required_scopes: ["files:write"]}} = EtsStore.get(server(), task_id)
    end

    test "tasks/get without the scopes gives 403 with the step-up scopes, with the scopes gives 200" do
      session_id = session("alice-admin")
      task_id = create_write_task(session_id)

      for method <- ["tasks/get", "tasks/result", "tasks/cancel"] do
        conn = rpc(3, method, %{"taskId" => task_id}, "alice-token", session_id)

        assert conn.status == 403, method

        assert get_resp_header(conn, "www-authenticate") == [
                 ~s(Bearer error="insufficient_scope", scope="files:read files:write", resource_metadata="#{@metadata_url}")
               ]
      end

      conn = rpc(4, "tasks/get", %{"taskId" => task_id}, "alice-admin", session_id)
      assert conn.status == 200
      assert :json.decode(conn.resp_body)["result"]["taskId"] == task_id
    end

    test "a refused tasks/cancel does not change the status" do
      session_id = session("alice-admin")
      owner = Tasks.owner_key(%{principal: alice(), session_id: session_id})
      record = put_working(owner, ["files:write"])

      conn = rpc(3, "tasks/cancel", %{"taskId" => record.task_id}, "alice-token", session_id)

      assert conn.status == 403
      assert {:ok, %{status: :working}} = EtsStore.get(server(), record.task_id)
    end

    test "an unknown task gives -32602, not 403" do
      session_id = session("alice-token")
      conn = rpc(3, "tasks/get", %{"taskId" => "nope"}, "alice-token", session_id)

      assert conn.status == 200
      assert :json.decode(conn.resp_body)["error"]["code"] == -32602
    end
  end

  describe "tasks/list" do
    test "does not show the task without the scopes" do
      session_id = session("alice-admin")
      task_id = create_write_task(session_id)

      conn = rpc(3, "tasks/list", %{}, "alice-token", session_id)
      assert conn.status == 200
      assert :json.decode(conn.resp_body)["result"]["tasks"] == []

      conn = rpc(4, "tasks/list", %{}, "alice-admin", session_id)
      tasks = :json.decode(conn.resp_body)["result"]["tasks"]
      assert Enum.map(tasks, & &1["taskId"]) == [task_id]
    end

    test "the cursor is the seq of the last visible task when tasks are hidden" do
      owner = Tasks.owner_key(%{principal: alice(), session_id: nil})

      visible1 = put_working(owner, [])
      _hidden1 = put_working(owner, ["files:write"])
      _hidden2 = put_working(owner, ["files:write"])
      visible2 = put_working(owner, ["files:read"])
      _hidden3 = put_working(owner, ["admin"])
      visible3 = put_working(owner, [])

      assert {:ok, page1, cursor} = Tasks.list(server(), owner, nil, 2, alice())
      assert Enum.map(page1, & &1.taskId) == [visible1.task_id, visible2.task_id]
      assert cursor == Integer.to_string(visible2.seq)

      assert {:ok, page2, nil} = Tasks.list(server(), owner, cursor, 2, alice())
      assert Enum.map(page2, & &1.taskId) == [visible3.task_id]
    end
  end

  describe "an open server" do
    test "lists each task" do
      owner = {:session, "open-session"}
      now = DateTime.utc_now()

      records =
        for scopes <- [[], ["files:write"], ["admin"]] do
          record = %EtsStore{
            task_id: OzMcp.Utils.Generator.task_id(),
            session_id: "open-session",
            owner_key: owner,
            seq: System.unique_integer([:monotonic, :positive]),
            status: :working,
            created_at: now,
            last_updated_at: now,
            required_scopes: scopes
          }

          :ok = Records.put(EtsStore, open(), record)
          record
        end

      assert {:ok, tasks, nil} = Tasks.list(open(), owner, nil, 10, nil)
      assert Enum.map(tasks, & &1.taskId) == Enum.map(records, & &1.task_id)
    end
  end
end
