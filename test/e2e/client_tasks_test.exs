#
# The full flow of a client task over HTTP: the server sends
# `sampling/createMessage` or `elicitation/create` with `params.task`, the
# client answers a `CreateTaskResult`, the server polls `tasks/get`, reads
# `tasks/result` and cancels the client task when it stops waiting. The
# cases cover a client with no task capability, the status hint, the
# terminal statuses, a timeout and a callback that runs inside a task of
# the server.
#
defmodule OzMcp.E2E.ClientTasksTest do
  use OzMcp.E2ECase, async: true

  alias OzMcp.E2E.ClientTasks
  alias OzMcp.Instance
  alias Support.Helpers.Utils
  alias Support.Servers

  @moduletag server: Servers.Outbound, server_opts: %{client_tasks: true}

  @task_id "c1"

  @task_capabilities %{
    "sampling" => %{},
    "elicitation" => %{"form" => %{}},
    "tasks" => %{
      "cancel" => %{},
      "requests" => %{
        "sampling" => %{"createMessage" => %{}},
        "elicitation" => %{"create" => %{}}
      }
    }
  }

  test "sampling as a client task: create, two polls, result", %{base_url: url} do
    client = ready(url, @task_capabilities)
    {client, response, sse} = call(client, "sample_task")
    call_id = client.next_id - 1

    {_client, _sse} =
      ClientTasks.run(client, response, sse, [
        {:create, client_task("working", %{"pollInterval" => 100})},
        {:get, "working"},
        {:get, "completed"},
        {:result, sample_result()}
      ])

    answer = final(response, sse, call_id)
    assert %{"result" => %{"content" => [%{"text" => text}]}} = answer
    assert text =~ "\"ok\""
  end

  test "a completed CreateTaskResult reads the result at once", %{base_url: url} do
    client = ready(url, @task_capabilities)
    {client, response, sse} = call(client, "sample_task")
    call_id = client.next_id - 1

    {_client, _sse} =
      ClientTasks.run(client, response, sse, [
        {:create, client_task("completed")},
        {:result, sample_result()}
      ])

    answer = final(response, sse, call_id)
    assert %{"result" => %{"content" => [%{"text" => text}]}} = answer
    assert text =~ "\"ok\""
  end

  test "elicitation as a client task: the answer goes through the schema check", %{
    base_url: url
  } do
    client = ready(url, @task_capabilities)
    {client, response, sse} = call(client, "elicit_task")
    call_id = client.next_id - 1

    {_client, _sse} =
      ClientTasks.run(client, response, sse, [
        {:create, client_task("working", %{"pollInterval" => 50})},
        {:get, "completed"},
        {:result, %{"action" => "accept", "content" => %{"name" => "Ada", "age" => 36}}}
      ])

    answer = final(response, sse, call_id)
    assert %{"result" => %{"content" => [%{"text" => text}]}} = answer
    assert text =~ "action: :accept"
    assert text =~ "\"Ada\""
    assert text =~ "36"
  end

  test "a client without the task capability gets a plain request", %{base_url: url} do
    client = ready(url, %{"sampling" => %{}})
    {client, response, sse} = call(client, "sample_task")
    call_id = client.next_id - 1

    {_client, _sse} =
      ClientTasks.run(client, response, sse, [{:plain, sample_result()}])

    answer = final(response, sse, call_id)
    assert %{"result" => %{"content" => [%{"text" => text}]}} = answer
    assert text =~ "\"ok\""
  end

  test "task_required: true without the task capability gives the error", %{base_url: url} do
    client = ready(url, %{"sampling" => %{}})

    {_client, {200, _headers, %{"result" => %{"content" => [%{"text" => text}]}}}} =
      Client.request(client, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{
          "feature" => "sample_task",
          "timeout" => 5_000,
          "task_required" => true
        }
      })

    assert text =~ "capability_not_supported"
  end

  test "notifications/tasks/status wakes the poll before the interval", %{
    base_url: url,
    instance: instance
  } do
    client = ready(url, @task_capabilities)
    {client, response, sse} = call(client, "sample_task")
    call_id = client.next_id - 1

    {create, sse} = ClientTasks.request(response, sse)
    assert create["method"] == "sampling/createMessage"

    {client, _answer} =
      Client.answer(client, create, %{
        "task" => client_task("working", %{"pollInterval" => 60_000})
      })

    assert Utils.eventually(fn ->
             Registry.lookup(
               Instance.topics(instance),
               {:client_task, {:session, client.session_id}, @task_id}
             ) != []
           end)

    start = System.monotonic_time(:millisecond)

    {client, {202, _headers, nil}} =
      Client.notify(client, "notifications/tasks/status", %{
        "taskId" => @task_id,
        "status" => "completed"
      })

    {get, sse} = ClientTasks.request(response, sse, 2_000)
    elapsed = System.monotonic_time(:millisecond) - start

    assert get["method"] == "tasks/get"
    assert elapsed < 1_000

    {client, _answer} = Client.answer(client, get, client_task("completed"))
    {result, sse} = ClientTasks.request(response, sse)
    assert result["method"] == "tasks/result"

    {_client, _answer} = Client.answer(client, result, sample_result())

    answer = final(response, sse, call_id)
    assert %{"result" => %{"content" => [%{"text" => text}]}} = answer
    assert text =~ "\"ok\""
  end

  test "a failed client task gives the error of its tasks/result", %{base_url: url} do
    client = ready(url, @task_capabilities)
    {client, response, sse} = call(client, "sample_task")
    call_id = client.next_id - 1

    {_client, _sse} =
      ClientTasks.run(client, response, sse, [
        {:create, client_task("working", %{"pollInterval" => 50})},
        {:get, "failed"},
        {:result_error, %{"code" => -32_603, "message" => "boom"}}
      ])

    answer = final(response, sse, call_id)
    assert %{"result" => %{"content" => [%{"text" => text}]}} = answer
    assert text =~ "rpc_error"
    assert text =~ "boom"
  end

  test "a cancelled client task gives its id and no tasks/result", %{base_url: url} do
    client = ready(url, @task_capabilities)
    {client, response, sse} = call(client, "sample_task")
    call_id = client.next_id - 1

    {_client, _sse} =
      ClientTasks.run(client, response, sse, [
        {:create, client_task("working", %{"pollInterval" => 50})},
        {:get, "cancelled"}
      ])

    answer = final(response, sse, call_id)
    assert %{"result" => %{"content" => [%{"text" => text}]}} = answer
    assert text =~ "client_task_cancelled"
    assert text =~ @task_id
  end

  test "a timeout sends tasks/cancel and gives :timeout", %{base_url: url} do
    client = ready(url, @task_capabilities)

    {client, response, sse} =
      call(client, "sample_task", %{"timeout" => 400, "after_delay" => 300})

    call_id = client.next_id - 1

    {_client, _sse} =
      ClientTasks.run(client, response, sse, [
        {:create, client_task("working", %{"pollInterval" => 100})},
        :expect_cancel
      ])

    answer = final(response, sse, call_id)
    assert %{"result" => %{"content" => [%{"text" => text}]}} = answer
    assert text =~ ":timeout"
  end

  test "an input_required client task reads tasks/result at once", %{base_url: url} do
    client = ready(url, @task_capabilities)
    {client, response, sse} = call(client, "sample_task")
    call_id = client.next_id - 1

    {_client, _sse} =
      ClientTasks.run(client, response, sse, [
        {:create, client_task("working", %{"pollInterval" => 50})},
        {:get, "input_required"},
        {:result, sample_result()}
      ])

    answer = final(response, sse, call_id)
    assert %{"result" => %{"content" => [%{"text" => text}]}} = answer
    assert text =~ "\"ok\""
  end

  @tag server: Servers.AuthorizedOutbound
  @tag server_opts: %{resource_url: "https://mcp.example.com/mcp", client_tasks: true}
  test "inside a task of the server the polls keep the status and another session answers", %{
    base_url: url
  } do
    owner = ready(url, "alice-token", @task_capabilities)
    second = ready(url, "alice-token", @task_capabilities)

    {_owner, {200, _headers, %{"result" => %{"task" => %{"taskId" => server_task_id}}}}} =
      Client.request(owner, "tools/call", server_task_call())

    {second, response, sse} =
      Client.stream_request(second, "tasks/result", %{"taskId" => server_task_id})

    result_id = second.next_id - 1

    {create, sse} = ClientTasks.request(response, sse)
    assert create["method"] == "sampling/createMessage"
    assert is_map(create["params"]["task"])

    {second, _answer} =
      Client.answer(second, create, %{
        "task" => client_task("working", %{"pollInterval" => 100})
      })

    {get, sse} = ClientTasks.request(response, sse)
    assert get["method"] == "tasks/get"

    # A poll travels on the attached stream, so the server task stays working.
    # The check waits for the poll: the answer of the client above reaches
    # the task after its 202, so an earlier read can still see input_required.
    #
    {_owner, {200, _headers, %{"result" => %{"status" => "working"}}}} =
      Client.request(owner, "tasks/get", %{"taskId" => server_task_id})

    {second, _answer} = Client.answer(second, get, client_task("completed"))

    {result, sse} = ClientTasks.request(response, sse)
    assert result["method"] == "tasks/result"

    {_second, _answer} = Client.answer(second, result, sample_result())

    answer = final(response, sse, result_id)
    assert %{"result" => %{"content" => [%{"text" => text}]}} = answer
    assert text =~ "\"ok\""
  end

  @tag server: Servers.AuthorizedOutbound
  @tag server_opts: %{resource_url: "https://mcp.example.com/mcp", client_tasks: true}
  test "a closed tasks/result stream makes the server task input_required and a new stream gets the poll",
       %{base_url: url, instance: instance} do
    owner = ready(url, "alice-token", @task_capabilities)
    second = ready(url, "alice-token", @task_capabilities)

    {_owner, {200, _headers, %{"result" => %{"task" => %{"taskId" => server_task_id}}}}} =
      Client.request(owner, "tools/call", server_task_call())

    {second, response, sse} =
      Client.stream_request(second, "tasks/result", %{"taskId" => server_task_id})

    stream_request_id = second.next_id - 1

    {create, _sse} = ClientTasks.request(response, sse)
    assert create["method"] == "sampling/createMessage"

    {second, _answer} =
      Client.answer(second, create, %{
        "task" => client_task("working", %{"pollInterval" => 1_000})
      })

    # The client cancels its tasks/result request and closes the stream
    # before the next poll is made.
    #
    {second, {202, _headers, nil}} =
      Client.notify(second, "notifications/cancelled", %{"requestId" => stream_request_id})

    Client.cancel_stream(response)

    assert Utils.eventually(fn -> task_streams(instance, server_task_id) == [] end)

    {_owner, %{"status" => "input_required"}} =
      poll_status(owner, server_task_id, "input_required")

    # A new stream of the owner gets the poll that the task still holds.
    #
    {second, response, sse} =
      Client.stream_request(second, "tasks/result", %{"taskId" => server_task_id})

    result_id = second.next_id - 1

    {get, sse} = ClientTasks.request(response, sse)
    assert get["method"] == "tasks/get"

    {second, _answer} = Client.answer(second, get, client_task("completed"))

    {result, sse} = ClientTasks.request(response, sse)
    assert result["method"] == "tasks/result"

    {_second, _answer} = Client.answer(second, result, sample_result())

    answer = final(response, sse, result_id)
    assert %{"result" => %{"content" => [%{"text" => text}]}} = answer
    assert text =~ "\"ok\""
  end

  test "a cancel of the server task sends tasks/cancel for the client task on the GET stream", %{
    base_url: url
  } do
    client = ready(url, @task_capabilities)
    {get_response, get_sse} = Client.open_get(client)

    {client, {200, _headers, %{"result" => %{"task" => %{"taskId" => server_task_id}}}}} =
      Client.request(client, "tools/call", server_task_call())

    {client, response, sse} =
      Client.stream_request(client, "tasks/result", %{"taskId" => server_task_id})

    {create, sse} = ClientTasks.request(response, sse)
    assert create["method"] == "sampling/createMessage"

    {client, _answer} =
      Client.answer(client, create, %{
        "task" => client_task("working", %{"pollInterval" => 50})
      })

    {get, _sse} = ClientTasks.request(response, sse)
    assert get["method"] == "tasks/get"

    {_client, {200, _headers, %{"result" => %{"status" => "cancelled"}}}} =
      Client.request(client, "tasks/cancel", %{"taskId" => server_task_id})

    {cancel, _get_sse} = wait_for_request(get_response, get_sse, "tasks/cancel")

    assert cancel["params"]["taskId"] == @task_id
  end

  defp ready(url, capabilities) do
    url |> Client.new() |> Client.ready!(capabilities: capabilities)
  end

  defp ready(url, token, capabilities) do
    url
    |> Client.new([{"authorization", "Bearer " <> token}])
    |> Client.ready!(capabilities: capabilities)
  end

  defp call(client, feature, arguments \\ %{}) do
    arguments = Map.merge(%{"feature" => feature, "timeout" => 5_000}, arguments)

    Client.stream_request(client, "tools/call", %{
      "name" => "outbound",
      "arguments" => arguments
    })
  end

  defp server_task_call do
    %{
      "name" => "outbound",
      "arguments" => %{
        "feature" => "sample_task",
        "timeout" => 10_000,
        "poll_interval" => 50
      },
      "task" => %{}
    }
  end

  defp client_task(status, extra \\ %{}) do
    Map.merge(
      %{
        "taskId" => @task_id,
        "status" => status,
        "createdAt" => "2026-01-01T00:00:00Z",
        "lastUpdatedAt" => "2026-01-01T00:00:00Z",
        "ttl" => 60_000
      },
      extra
    )
  end

  defp sample_result do
    %{
      "role" => "assistant",
      "model" => "m",
      "content" => %{"type" => "text", "text" => "ok"}
    }
  end

  defp final(response, sse, request_id, tries \\ 200)

  defp final(_response, _sse, _request_id, 0),
    do: flunk("the response of the tool never arrived")

  defp final(response, sse, request_id, tries) do
    case Client.next_event(response, sse, 1_000) do
      {:ok, event, sse} ->
        case JSON.decode!(event.data) do
          %{"id" => ^request_id} = answer -> answer
          _other -> final(response, sse, request_id, tries - 1)
        end

      {:ended, _sse} ->
        flunk("the stream ended before the response of the tool")
    end
  end

  defp wait_for_request(response, sse, method, tries \\ 200)

  defp wait_for_request(_response, _sse, _method, 0),
    do: flunk("no request of the server arrived on the stream")

  defp wait_for_request(response, sse, method, tries) do
    case Client.next_event(response, sse, 1_000) do
      {:ok, event, sse} ->
        case JSON.decode!(event.data) do
          %{"method" => ^method, "id" => _id} = request -> {request, sse}
          _other -> wait_for_request(response, sse, method, tries - 1)
        end

      {:ended, _sse} ->
        flunk("the GET stream ended before the request")
    end
  end

  defp poll_status(client, task_id, wanted) do
    assert Utils.eventually(fn ->
             match?(
               {_client, {200, _headers, %{"result" => %{"status" => ^wanted}}}},
               Client.request(client, "tasks/get", %{"taskId" => task_id})
             )
           end)

    {_client, {200, _headers, %{"result" => task}}} =
      Client.request(client, "tasks/get", %{"taskId" => task_id})

    {client, task}
  end

  defp task_streams(instance, task_id) do
    case Registry.lookup(Instance.names(instance), {:task, task_id}) do
      [{pid, _value}] ->
        case :sys.get_state(pid) do
          {_status, data} -> data.streams
        end

      [] ->
        []
    end
  end
end
