#
# The tasks over a real connection: a task-augmented `tools/call` answers
# a task record at once and runs the tool in the background, the client
# polls `tasks/get`, lists its tasks, cancels a working task and collects
# the result with `tasks/result`. A task that asks the client moves to
# `input_required` and its request travels on the stream of the open
# `tasks/result` with the related-task `_meta`. A call above the limit of
# the active tasks gets the error `too many tasks`.
#
defmodule OzMcp.E2E.TasksTest do
  use OzMcp.E2ECase, async: true

  alias OzMcp.Tasks
  alias Support.Helpers.Utils
  alias Support.Servers

  @default_ttl 86_400_000

  test "a task-augmented tools/call answers a task record and runs the tool", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {client, {200, _headers, %{"result" => %{"task" => task}}}, _runner} =
      call_slow_task(client)

    assert is_binary(task["taskId"]) and task["taskId"] != ""
    assert task["status"] == "working"
    assert task["ttl"] == @default_ttl
    assert String.match?(task["createdAt"], ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
    assert String.match?(task["lastUpdatedAt"], ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)

    # The tool still runs: the record is not terminal until it answers.
    #
    {client, {200, _headers, %{"result" => %{"status" => "working"}}}} =
      Client.request(client, "tasks/get", %{"taskId" => task["taskId"]})

    Support.Entities.Tools.TaskSlowTest.finish()

    {client, %{"status" => "completed"}} = poll_status(client, task["taskId"], "completed")

    {_client, {200, _headers, %{"result" => result}}} =
      Client.request(client, "tasks/result", %{"taskId" => task["taskId"]})

    assert result["content"] == [%{"type" => "text", "text" => "slow done"}]
    assert result["_meta"] == related_task(task["taskId"])
  end

  test "a task stream gets only the progress values that increase", %{
    base_url: url,
    instance: instance
  } do
    client = url |> Client.new() |> Client.ready!()
    previous = Support.Entities.Tools.TaskSlowTest.last_runner_pid()

    {client, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(client, "tools/call", %{
        "name" => "task_slow",
        "task" => %{},
        "_meta" => %{"progressToken" => "tok-progress"}
      })

    runner = Support.Entities.Tools.TaskSlowTest.await_runner(previous)

    result_id = client.next_id

    producer =
      Task.async(fn ->
        assert Utils.eventually(fn ->
                 case Registry.lookup(OzMcp.Instance.names(instance), {:task, task_id}) do
                   [{pid, _value}] -> match?({_status, %{streams: [_ | _]}}, :sys.get_state(pid))
                   [] -> false
                 end
               end)

        for value <- [1, 2, 2, 1, 3] do
          assert :ok = Tasks.progress(instance, task_id, value, 10, nil)
        end

        Utils.sync_task(instance, task_id)

        # The `Task` process has no instance of `Support.Entities.Tools.TaskSlowTest.use_instance/1`
        # (it is in the dictionary of the test process): `finish/0` here
        # would end the slow runner of another test. The pid ends this one.
        #
        send(runner, :finish)
      end)

    {_client, response, sse} =
      Client.stream_request(client, "tasks/result", %{"taskId" => task_id})

    Task.await(producer, 10_000)

    {answer_message, _sse, values} = progress_until_response(response, sse, result_id)

    assert %{"id" => ^result_id} = answer_message
    assert values == [1, 2, 3]
  end

  test "a flood of logs of a task is rate limited on the tasks/result stream", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {client, {200, _headers, %{"result" => %{}}}} =
      Client.request(client, "logging/setLevel", %{"level" => "info"})

    {client, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(client, "tools/call", %{
        "name" => "log",
        "arguments" => %{"count" => 500, "delay" => 1_000},
        "task" => %{}
      })

    result_id = client.next_id

    {_client, response, sse} =
      Client.stream_request(client, "tasks/result", %{"taskId" => task_id})

    {answer, logs} = logs_until_response(response, sse, result_id)

    assert %{"id" => ^result_id} = answer

    # The session of the stream accepts only the messages under
    # `max_log_rate` (the default, 100 for each second) and the result
    # of the task is the last event of the stream.
    #
    assert logs > 0
    assert logs < 500
  end

  test "tasks/result of a task that is already completed gives the stored result again", %{
    base_url: url
  } do
    client = url |> Client.new() |> Client.ready!()

    {client, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}, _runner} =
      call_slow_task(client)

    Support.Entities.Tools.TaskSlowTest.finish()

    {client, %{"status" => "completed"}} = poll_status(client, task_id, "completed")

    # The record of a completed task stays until the end of its TTL: the
    # client can read the result again, for example after a lost
    # connection.
    #
    for _ <- 1..2 do
      {_client, {200, _headers, %{"result" => result}}} =
        Client.request(client, "tasks/result", %{"taskId" => task_id})

      assert result["content"] == [%{"type" => "text", "text" => "slow done"}]
      assert result["_meta"] == related_task(task_id)
    end
  end

  test "tasks/get of an unknown task gives -32602", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, _headers, %{"error" => error}}} =
      Client.request(client, "tasks/get", %{"taskId" => "no-such-task"})

    assert error["code"] == -32602
    assert error["message"] == "Failed to retrieve task: Task not found"
  end

  test "tasks/list gives the tasks of the session", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {client, {200, _headers, %{"result" => %{"task" => first}}}} = call_task(client, "task_slow")
    {client, {200, _headers, %{"result" => %{"task" => second}}}} = call_task(client, "task_slow")

    {_client, {200, _headers, %{"result" => %{"tasks" => tasks}}}} =
      Client.request(client, "tasks/list")

    ids = Enum.map(tasks, & &1["taskId"])
    assert first["taskId"] in ids and second["taskId"] in ids

    Support.Entities.Tools.TaskSlowTest.finish()
  end

  test "tasks/cancel stops a working task, kills the runner and stores the outcome", %{
    base_url: url
  } do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}, runner} =
      call_slow_task(client)

    {_client, {200, _headers, %{"result" => task}}} =
      Client.request(client, "tasks/cancel", %{"taskId" => task_id})

    assert task["status"] == "cancelled"
    assert task["statusMessage"] == "The task was cancelled by request."

    # The cancel kills the runner: the DOWN of the runner arrives.
    #
    runner_ref = Process.monitor(runner)
    assert_receive {:DOWN, ^runner_ref, :process, ^runner, _}, 5_000

    {_client, {200, _headers, %{"error" => error}}} =
      Client.request(client, "tasks/result", %{"taskId" => task_id})

    assert error["code"] == -32800
    assert error["message"] == "task was cancelled"
    assert error["data"] == %{"_meta" => related_task(task_id)}
  end

  @tag server_opts: %{max_tasks_per_session: 1}
  test "the second active task gets too many tasks", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {client, {200, _headers, %{"result" => %{"task" => _first}}}, _runner} =
      call_slow_task(client)

    {_client, {200, _headers, %{"error" => error}}} = call_task(client, "task_slow")

    assert error["code"] == -32000
    assert error["message"] == "too many tasks"
    assert error["data"] == %{"limit" => "max_tasks_per_session"}

    Support.Entities.Tools.TaskSlowTest.finish()
  end

  # The record limits count every record of the owner, also a task that a
  # bad input made terminal at its creation. A create over the limit is
  # refused and the records stay until their TTL.
  #
  @tag server: Servers.TasksRequiredTool
  @tag server_opts: %{
         max_task_records_per_owner: 5,
         max_tasks_per_session: nil,
         max_tasks_per_principal: nil
       }
  test "a loop of task calls with bad input stops at the record limit", %{
    base_url: url,
    instance: instance
  } do
    client = url |> Client.new() |> Client.ready!()

    {answers, client} =
      Enum.map_reduce(1..500, client, fn _step, client ->
        {client, {200, _headers, body}} =
          Client.request(client, "tools/call", %{
            "name" => "full",
            "arguments" => %{"name" => 123},
            "task" => %{}
          })

        {body, client}
      end)

    tasks = for %{"result" => %{"task" => task}} <- answers, do: task
    errors = for %{"error" => error} <- answers, do: error

    assert length(tasks) == 5
    assert Enum.all?(tasks, &(&1["status"] == "failed"))
    assert length(errors) == 495

    assert Enum.all?(
             errors,
             &(&1["code"] == -32000 and &1["message"] == "too many tasks" and
                 &1["data"] == %{"limit" => "max_task_records_per_owner"})
           )

    assert {:ok, records, _cursor} =
             Tasks.list(instance, {:session, client.session_id}, nil, 100)

    assert length(records) == 5
  end

  @tag server: Servers.TasksTest
  @tag server_opts: %{
         max_task_records_per_owner: 5,
         max_tasks_per_session: nil,
         max_tasks_per_principal: nil
       }
  test "a loop of fast tasks stops at the record limit", %{
    base_url: url,
    instance: instance
  } do
    client = url |> Client.new() |> Client.ready!()

    {answers, client} =
      Enum.map_reduce(1..500, client, fn _step, client ->
        {client, {200, _headers, body}} = call_task(client, "task_immediate")
        {body, client}
      end)

    tasks = for %{"result" => %{"task" => task}} <- answers, do: task
    errors = for %{"error" => error} <- answers, do: error

    assert length(tasks) == 5
    assert length(errors) == 495

    assert Enum.all?(
             errors,
             &(&1["code"] == -32000 and &1["message"] == "too many tasks" and
                 &1["data"] == %{"limit" => "max_task_records_per_owner"})
           )

    assert {:ok, records, _cursor} =
             Tasks.list(instance, {:session, client.session_id}, nil, 100)

    assert length(records) == 5
  end

  @tag server: Servers.AuthorizedIsolation
  @tag server_opts: %{
         resource_url: "https://mcp.example.com/mcp",
         max_task_records_per_owner: 5,
         max_tasks_per_session: nil,
         max_tasks_per_principal: nil
       }
  test "two sessions of one principal share the record limit", %{base_url: url} do
    first = authorized(url, "alice-token")
    second = authorized(url, "alice-token")

    {first_answers, _first} =
      Enum.map_reduce(1..3, first, fn _step, client ->
        {client, {200, _headers, body}} = call_task(client, "task_immediate")
        {body, client}
      end)

    {second_answers, _second} =
      Enum.map_reduce(1..3, second, fn _step, client ->
        {client, {200, _headers, body}} = call_task(client, "task_immediate")
        {body, client}
      end)

    assert Enum.all?(first_answers, &match?(%{"result" => %{"task" => _}}, &1))
    assert Enum.all?(Enum.take(second_answers, 2), &match?(%{"result" => %{"task" => _}}, &1))

    assert %{"error" => error} = List.last(second_answers)
    assert error["code"] == -32000
    assert error["message"] == "too many tasks"
    assert error["data"] == %{"limit" => "max_task_records_per_owner"}
  end

  # The request of a task in input_required travels on the stream of the
  # open tasks/result. The client answers with a POST that carries the
  # JSON-RPC response and the answer of the task is the last event of
  # the stream.
  #
  @tag server: Servers.Outbound
  test "the elicitation of a task in input_required travels on the tasks/result stream", %{
    base_url: url
  } do
    capabilities = %{"elicitation" => %{"form" => %{}}}
    client = url |> Client.new() |> Client.ready!(capabilities: capabilities)

    {client, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(client, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"feature" => "elicit_form", "timeout" => 10_000},
        "task" => %{}
      })

    {client, _task} = poll_status(client, task_id, "input_required")

    {client, response, sse} =
      Client.stream_request(client, "tasks/result", %{"taskId" => task_id})

    result_id = client.next_id - 1

    {:ok, event, sse} = Client.next_event(response, sse)
    request = JSON.decode!(event.data)

    assert %{"method" => "elicitation/create", "id" => request_id, "params" => params} = request

    assert is_binary(request_id) and request_id != ""
    assert params["_meta"] == related_task(task_id)
    assert params["mode"] == "form"
    assert params["message"] == "Who are you?"

    {client, {202, _headers, nil}} =
      Client.answer(client, request, %{"action" => "accept", "content" => %{"name" => "Ana"}})

    # The stream can carry a status notification between the answer and
    # the result of the request.
    #
    {answer_message, sse} = wait_for_response(response, sse, result_id)

    assert %{"id" => ^result_id, "result" => result} = answer_message

    assert [%{"text" => text}] = result["content"]
    assert text =~ "action: :accept"
    assert result["_meta"] == related_task(task_id)

    # The answer of tasks/result is the last event of the stream.
    #
    {:ended, _sse} = Client.next_frame(response, sse)

    {_client, %{"status" => "completed"}} = poll_status(client, task_id, "completed")
  end

  @tag server: OzMcp.E2E.BadShapeServer
  @tag :capture_log
  test "a task tool with a bad result shape gives a failed task and -32603", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {client, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(client, "tools/call", %{
        "name" => "task_bad_shape",
        "arguments" => %{"shape" => "empty_map"},
        "task" => %{}
      })

    {client, %{"status" => "failed"}} = poll_status(client, task_id, "failed")

    {_client, {200, _headers, %{"error" => error}}} =
      Client.request(client, "tasks/result", %{"taskId" => task_id})

    assert error["code"] == -32603
    assert error["message"] == "internal error"
    assert error["data"]["_meta"] == related_task(task_id)
  end

  @tag server: OzMcp.E2E.BadShapeServer
  @tag :capture_log
  test "a task tool with a bad member type gives a failed task and -32603", %{base_url: url} do
    for shape <- ["bad_content", "bad_is_error", "bad_structured"] do
      client = url |> Client.new() |> Client.ready!()

      {client, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
        Client.request(client, "tools/call", %{
          "name" => "task_bad_shape",
          "arguments" => %{"shape" => shape},
          "task" => %{}
        })

      {client, %{"status" => "failed"}} = poll_status(client, task_id, "failed")

      {_client, {200, _headers, %{"error" => error}}} =
        Client.request(client, "tasks/result", %{"taskId" => task_id})

      assert error["code"] == -32603
      assert error["message"] == "internal error"
      assert error["data"]["_meta"] == related_task(task_id)
    end
  end

  defp call_task(client, tool) do
    Client.request(client, "tools/call", %{"name" => tool, "task" => %{}})
  end

  defp authorized(url, token) do
    url |> Client.new([{"authorization", "Bearer " <> token}]) |> Client.ready!()
  end

  # The runner of the slow tool stores its pid in :persistent_term, one
  # value for the whole test run: the pid of another test can still be
  # there when this test reads it. The call remembers the pid before the
  # task and the wait accepts a new, alive pid only.
  #
  defp call_slow_task(client) do
    previous = Support.Entities.Tools.TaskSlowTest.last_runner_pid()
    {client, answer} = call_task(client, "task_slow")
    {client, answer, Support.Entities.Tools.TaskSlowTest.await_runner(previous)}
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

  defp related_task(task_id) do
    %{"io.modelcontextprotocol/related-task" => %{"taskId" => task_id}}
  end

  # The events of a `tasks/result` stream until the response of the
  # request arrives. It also collects the progress values of the stream.
  #
  defp progress_until_response(response, sse, request_id, values \\ []) do
    case Client.next_event(response, sse, 5_000) do
      {:ok, event, sse} ->
        case JSON.decode!(event.data) do
          %{"id" => ^request_id} = message ->
            {message, sse, Enum.reverse(values)}

          %{"method" => "notifications/progress", "params" => %{"progress" => value}} ->
            progress_until_response(response, sse, request_id, [value | values])

          %{"method" => _method} ->
            progress_until_response(response, sse, request_id, values)
        end

      {:ended, _sse} ->
        flunk("the tasks/result stream ended before the response")
    end
  end

  # The log notifications of a `tasks/result` stream until the response
  # of the request arrives. Status notifications of the task can come
  # first.
  #
  defp logs_until_response(response, sse, request_id, logs \\ 0) do
    case Client.next_event(response, sse, 5_000) do
      {:ok, event, sse} ->
        case JSON.decode!(event.data) do
          %{"id" => ^request_id} = message ->
            {message, logs}

          %{"method" => "notifications/message"} ->
            logs_until_response(response, sse, request_id, logs + 1)

          %{"method" => _method} ->
            logs_until_response(response, sse, request_id, logs)
        end

      {:ended, _sse} ->
        flunk("the tasks/result stream ended before the response")
    end
  end

  # The events of a `tasks/result` stream until the response of the
  # request arrives: status notifications of the task can come first.
  #
  defp wait_for_response(response, sse, request_id, tries \\ 100)

  defp wait_for_response(_response, _sse, _request_id, 0),
    do: flunk("the response of the request never arrived")

  defp wait_for_response(response, sse, request_id, tries) do
    case Client.next_event(response, sse, 1_000) do
      {:ok, event, sse} ->
        case JSON.decode!(event.data) do
          %{"id" => ^request_id} = message -> {message, sse}
          %{"method" => _method} -> wait_for_response(response, sse, request_id, tries - 1)
        end

      {:ended, _sse} ->
        flunk("the tasks/result stream ended before the response")
    end
  end
end
