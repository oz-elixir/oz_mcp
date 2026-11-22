#
# The owner of a task over a real connection. The tasks belong to the
# principal that created them: two sessions of one principal see the same
# tasks and another principal sees none of them. The option
# `tasks_follow_session` decides whether a task outlives its session and
# `max_tasks_per_principal` limits the active tasks of a principal across
# its sessions.
#
# The tests on the server with the tools that ask the client check the
# whole path across the sessions of the owner: the request of a task
# reaches every `tasks/result` stream of the owner, one answer is enough,
# an answer of another principal, a forged answer and a late answer change
# nothing and the status, the log and the progress of a task follow its
# owner.
#
defmodule OzMcp.E2E.TasksOwnerTest do
  use OzMcp.E2ECase, async: true
  alias Support.Helpers.Utils
  alias Support.Servers

  @moduletag server: Servers.AuthorizedIsolation
  @moduletag server_opts: %{resource_url: "https://mcp.example.com/mcp"}

  test "two sessions of one principal see the same tasks", %{base_url: url} do
    first = ready(url, "alice-token")
    second = ready(url, "alice-token")

    {_first, {200, _headers, %{"result" => %{"task" => task}}}} = call_task(first, "task_slow")
    task_id = task["taskId"]

    {second, {200, _headers, %{"result" => %{"tasks" => tasks}}}} =
      Client.request(second, "tasks/list")

    assert Enum.map(tasks, & &1["taskId"]) == [task_id]

    {_second, {200, _headers, %{"result" => %{"taskId" => ^task_id}}}} =
      Client.request(second, "tasks/get", %{"taskId" => task_id})

    wait_for_runner()

    Support.Entities.Tools.TaskSlowTest.finish()
  end

  test "two principals do not see the tasks of each other", %{base_url: url} do
    alice = ready(url, "alice-token")
    bob = ready(url, "bob-token")

    {_alice, {200, _headers, %{"result" => %{"task" => task}}}} = call_task(alice, "task_slow")
    task_id = task["taskId"]

    {bob, {200, _headers, %{"result" => %{"tasks" => []}}}} = Client.request(bob, "tasks/list")

    for method <- ["tasks/get", "tasks/result", "tasks/cancel"] do
      {_bob, {200, _headers, %{"error" => error}}} =
        Client.request(bob, method, %{"taskId" => task_id})

      assert error["code"] == -32602
    end

    wait_for_runner()

    Support.Entities.Tools.TaskSlowTest.finish()
  end

  @tag server_opts: %{
         resource_url: "https://mcp.example.com/mcp",
         tasks_follow_session: false
       }
  test "tasks_follow_session false: a task continues after the DELETE", %{base_url: url} do
    first = ready(url, "alice-token")

    {first, {200, _headers, %{"result" => %{"task" => task}}}} = call_task(first, "task_slow")
    task_id = task["taskId"]

    {_first, {200, _headers, _body}} = Client.delete(first)

    second = ready(url, "alice-token")

    {second, {200, _headers, %{"result" => %{"status" => "working"}}}} =
      Client.request(second, "tasks/get", %{"taskId" => task_id})

    wait_for_runner()

    Support.Entities.Tools.TaskSlowTest.finish()

    {_second, {200, _headers, body}} =
      Client.request(second, "tasks/result", %{"taskId" => task_id})

    # The response can arrive as an event stream that carries the terminal
    # status notification before the result of the request.
    #
    result =
      case body do
        %{"result" => result} ->
          result

        events when is_list(events) ->
          events
          |> Enum.reject(&(&1.data == ""))
          |> Enum.map(&JSON.decode!(&1.data))
          |> Enum.find(&Map.has_key?(&1, "result"))
          |> Map.fetch!("result")
      end

    assert result["content"] == [%{"type" => "text", "text" => "slow done"}]
  end

  test "tasks_follow_session true: the DELETE stops the task", %{base_url: url} do
    first = ready(url, "alice-token")

    {first, {200, _headers, %{"result" => %{"task" => task}}}} = call_task(first, "task_slow")
    task_id = task["taskId"]

    {_first, {200, _headers, _body}} = Client.delete(first)

    second = ready(url, "alice-token")

    wait_for_error(second, task_id)
  end

  @tag server_opts: %{
         resource_url: "https://mcp.example.com/mcp",
         max_tasks_per_principal: 1
       }
  test "max_tasks_per_principal counts the tasks of all the sessions", %{base_url: url} do
    first = ready(url, "alice-token")
    second = ready(url, "alice-token")
    bob = ready(url, "bob-token")

    {_first, {200, _headers, %{"result" => %{"task" => _task}}}} = call_task(first, "task_slow")

    {_second, {200, _headers, %{"error" => error}}} = call_task(second, "task_slow")
    assert error["code"] == -32000
    assert error["message"] == "too many tasks"
    assert error["data"] == %{"limit" => "max_tasks_per_principal"}

    {_bob, {200, _headers, %{"result" => %{"task" => _other}}}} = call_task(bob, "task_slow")

    wait_for_runner()

    Support.Entities.Tools.TaskSlowTest.finish()
  end

  test "the GET stream of session B gets the status of a task of session A", %{base_url: url} do
    token = "alice-token"
    a = ready(url, token)
    b = ready(url, token)

    {get, sse} =
      Client.open_get(b, headers: [{"authorization", "Bearer " <> token}])

    {_a, {200, _headers, %{"result" => %{"task" => task}}}} = call_task(a, "task_slow")

    wait_for_runner()
    Support.Entities.Tools.TaskSlowTest.finish()

    %{params: params} = wait_for_status(get, sse, task["taskId"])
    assert params["status"] == "completed"
  end

  @tag server_opts: %{
         resource_url: "https://mcp.example.com/mcp",
         tasks_follow_session: false
       }
  test "tasks_follow_session false: the GET stream of session B gets the status after the DELETE of session A",
       %{base_url: url} do
    token = "alice-token"
    a = ready(url, token)

    {_a, {200, _headers, %{"result" => %{"task" => task}}}} = call_task(a, "task_slow")

    {_a, {200, _headers, _body}} = Client.delete(a)

    b = ready(url, token)

    {get, sse} =
      Client.open_get(b, headers: [{"authorization", "Bearer " <> token}])

    wait_for_runner()
    Support.Entities.Tools.TaskSlowTest.finish()

    %{params: params} = wait_for_status(get, sse, task["taskId"])
    assert params["status"] == "completed"
  end

  @tag server: Servers.AuthorizedOutbound
  @tag server_opts: %{
         resource_url: "https://mcp.example.com/mcp",
         tasks_follow_session: false
       }
  test "tasks_follow_session false: session B answers the request of a task of the deleted session A",
       %{base_url: url} do
    capabilities = %{"elicitation" => %{"form" => %{}}}
    a = ready(url, "alice-token", capabilities)
    b = ready(url, "alice-token", capabilities)

    {_a, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(a, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"feature" => "elicit_form", "timeout" => 10_000},
        "task" => %{}
      })

    {_a, {200, _headers, _body}} = Client.delete(a)

    {b, response, sse} = Client.stream_request(b, "tasks/result", %{"taskId" => task_id})
    result_id = b.next_id - 1

    {request, sse} = wait_for_request(response, sse, "elicitation/create")
    assert %{"id" => "t." <> _rest} = request

    {_b, {202, _headers, nil}} =
      Client.answer(b, request, %{"action" => "accept", "content" => %{"name" => "Ana"}})

    assert %{"id" => ^result_id, "result" => %{"content" => [%{"text" => text}]}} =
             wait_for_answer(response, sse, result_id)

    assert text =~ "action: :accept"
    assert text =~ "\"Ana\""
  end

  @tag server: Servers.AuthorizedOutbound
  @tag server_opts: %{
         resource_url: "https://mcp.example.com/mcp",
         tasks_follow_session: false
       }
  test "the end of session A ends its tasks/result wait and session B gets the result",
       %{base_url: url} do
    capabilities = %{"elicitation" => %{"form" => %{}}}
    a = ready(url, "alice-token", capabilities)

    {_a, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(a, "tools/call", elicit_task(10_000))

    {a, a_response, a_sse} = Client.stream_request(a, "tasks/result", %{"taskId" => task_id})

    # The held request of the task reaches the stream of session A.
    #
    {request, _a_sse} = wait_for_request(a_response, a_sse, "elicitation/create")
    assert %{"id" => "t." <> _rest} = request

    # Session A does not answer and is deleted. Its tasks/result wait ends.
    #
    {_a, {200, _headers, _body}} = Client.delete(a)

    # The task goes on. Session B of the same principal reads the task,
    # gets the request that the task still holds and answers it.
    #
    b = ready(url, "alice-token", capabilities)

    {b, {200, _headers, %{"result" => %{"status" => status}}}} =
      Client.request(b, "tasks/get", %{"taskId" => task_id})

    assert status in ["working", "input_required"]

    {b, b_response, b_sse} = Client.stream_request(b, "tasks/result", %{"taskId" => task_id})
    b_result_id = b.next_id - 1

    {b_request, b_sse} = wait_for_request(b_response, b_sse, "elicitation/create")
    assert b_request["id"] == request["id"]

    {_b, {202, _headers, nil}} =
      Client.answer(b, b_request, %{"action" => "accept", "content" => %{"name" => "Ana"}})

    assert %{"id" => ^b_result_id, "result" => %{"content" => [_ | _]}} =
             wait_for_answer(b_response, b_sse, b_result_id)
  end

  @tag server: Servers.AuthorizedOutbound
  test "a tasks/result stream gets the held request and the notifications with the ids that the session gives",
       %{base_url: url} do
    capabilities = %{"elicitation" => %{"form" => %{}}}
    a = ready(url, "alice-token", capabilities)
    b = ready(url, "alice-token", capabilities)

    {_a, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(a, "tools/call", elicit_task(10_000))

    {b, response, sse} = Client.stream_request(b, "tasks/result", %{"taskId" => task_id})
    result_id = b.next_id - 1

    # The held request of the task reaches the stream.
    #
    {:ok, frames1, request, sse} =
      frames_until(response, sse, fn
        %{"method" => "elicitation/create", "id" => "t." <> _} -> true
        _other -> false
      end)

    {_b, {202, _headers, nil}} =
      Client.answer(b, request, %{"action" => "accept", "content" => %{"name" => "Ana"}})

    # The wait ends at the outcome of the task: the response of the
    # request is the last message of the stream.
    #
    {:ok, frames2, answer, _sse} =
      frames_until(response, sse, &match?(%{"id" => ^result_id}, &1))

    frames = frames1 ++ frames2
    assert answer["result"]

    messages = for %{data: data} <- frames, data != "", do: JSON.decode!(data)

    assert Enum.any?(
             messages,
             &match?(%{"method" => "elicitation/create", "id" => "t." <> _}, &1)
           )

    assert Enum.any?(
             messages,
             &match?(
               %{"method" => "notifications/tasks/status", "params" => %{"taskId" => ^task_id}},
               &1
             )
           )

    # Every event of the stream carries the id that the session gave: the
    # priming id of the stream, then one number after the other.
    #
    assert [%{id: priming_id, data: ""} | _] = frames
    assert String.ends_with?(priming_id, ":0")
    stream_id = binary_part(priming_id, 0, byte_size(priming_id) - 2)

    numbers =
      for %{id: id} <- frames, id != nil do
        assert String.starts_with?(id, stream_id <> ":")
        {n, ""} = id |> String.trim_leading(stream_id <> ":") |> Integer.parse()
        n
      end

    assert numbers == Enum.to_list(0..(length(numbers) - 1))
  end

  @tag server: Servers.AuthorizedOutbound
  test "the last status notification of a task comes before the response on the tasks/result stream",
       %{base_url: url} do
    a = ready(url, "alice-token")
    b = ready(url, "alice-token")

    {_a, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(a, "tools/call", %{
        "name" => "progress",
        "arguments" => %{"delay" => 300},
        "_meta" => %{"progressToken" => "pt-1"},
        "task" => %{}
      })

    {b, response, sse} = Client.stream_request(b, "tasks/result", %{"taskId" => task_id})
    result_id = b.next_id - 1

    # A progress message proves that the stream is attached: the task
    # sends its notifications only to the attached streams. The task ends
    # by itself, so the last status notification and the response follow.
    #
    {:ok, frames, answer, _sse} =
      frames_until(response, sse, &match?(%{"id" => ^result_id}, &1))

    assert answer["result"]["content"] == [%{"type" => "text", "text" => "progress done"}]

    events = for %{data: data} <- frames, data != "", do: JSON.decode!(data)

    status =
      Enum.find_index(
        events,
        &match?(
          %{"method" => "notifications/tasks/status", "params" => %{"status" => "completed"}},
          &1
        )
      )

    assert is_integer(status)
    assert Enum.any?(events, &match?(%{"method" => "notifications/progress"}, &1))

    # The response is the last message of the stream: the completed status
    # went out before it.
    #
    assert List.last(events) == answer
    assert status == length(events) - 2
  end

  @tag server: Servers.AuthorizedOutbound
  test "session B answers the elicitation of a task that session A created", %{base_url: url} do
    capabilities = %{"elicitation" => %{"form" => %{}}}
    a = ready(url, "alice-token", capabilities)
    b = ready(url, "alice-token", capabilities)

    {_a, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(a, "tools/call", elicit_task(10_000))

    {b, response, sse} = Client.stream_request(b, "tasks/result", %{"taskId" => task_id})
    result_id = b.next_id - 1

    {request, sse} = wait_for_request(response, sse, "elicitation/create")

    assert %{"id" => "t." <> _rest, "params" => params} = request
    assert params["_meta"] == related_task(task_id)

    {_b, {202, _headers, nil}} =
      Client.answer(b, request, %{"action" => "accept", "content" => %{"name" => "Ana"}})

    assert %{"id" => ^result_id, "result" => %{"content" => [%{"text" => text}]}} =
             wait_for_answer(response, sse, result_id)

    assert text =~ "action: :accept"
    assert text =~ "\"Ana\""
  end

  @tag server: Servers.AuthorizedOutbound
  test "the answer of another principal does not reach the task", %{base_url: url} do
    capabilities = %{"elicitation" => %{"form" => %{}}}
    a = ready(url, "alice-token", capabilities)
    b = ready(url, "alice-token", capabilities)
    bob = ready(url, "bob-token", capabilities)

    {_a, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(a, "tools/call", elicit_task(10_000))

    {_b, response, sse} = Client.stream_request(b, "tasks/result", %{"taskId" => task_id})
    {request, sse} = wait_for_request(response, sse, "elicitation/create")

    # Bob posts a response for the request of Alice: the router accepts
    # the message, the task never sees it.
    #
    {_bob, {202, _headers, nil}} =
      Client.answer(bob, request, %{"action" => "accept", "content" => %{"name" => "Eve"}})

    # The request was still held: the cancel tells the client to forget it.
    #
    {_a, {200, _headers, %{"result" => %{"status" => "cancelled"}}}} =
      Client.request(a, "tasks/cancel", %{"taskId" => task_id})

    {notice, _sse} = wait_for_notice(response, sse, "notifications/cancelled")

    assert notice["params"]["requestId"] == request["id"]
    assert notice["params"]["_meta"] == related_task(task_id)
  end

  @tag server: Servers.AuthorizedOutbound
  test "two sessions read the task: one answer is enough", %{base_url: url} do
    capabilities = %{"elicitation" => %{"form" => %{}}}
    a = ready(url, "alice-token", capabilities)
    first = ready(url, "alice-token", capabilities)
    second = ready(url, "alice-token", capabilities)

    {_a, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(a, "tools/call", elicit_task(10_000))

    {first, response1, sse1} =
      Client.stream_request(first, "tasks/result", %{"taskId" => task_id})

    first_id = first.next_id - 1

    {second, response2, sse2} =
      Client.stream_request(second, "tasks/result", %{"taskId" => task_id})

    second_id = second.next_id - 1

    {request1, sse1} = wait_for_request(response1, sse1, "elicitation/create")
    {request2, sse2} = wait_for_request(response2, sse2, "elicitation/create")
    assert request1["id"] == request2["id"]

    {_first, {202, _headers, nil}} =
      Client.answer(first, request1, %{"action" => "accept", "content" => %{"name" => "Ana"}})

    assert %{"id" => ^first_id, "result" => %{"content" => [%{"text" => text}]}} =
             wait_for_answer(response1, sse1, first_id)

    assert %{"id" => ^second_id, "result" => %{"content" => [%{"text" => ^text}]}} =
             wait_for_answer(response2, sse2, second_id)

    # The second answer is ignored: the request is gone.
    #
    {_second, {202, _headers, nil}} =
      Client.answer(second, request2, %{"action" => "accept", "content" => %{"name" => "Late"}})
  end

  @tag server: Servers.Outbound
  @tag server_opts: %{}
  test "without authorization another session cannot read the task or answer it", %{
    base_url: url
  } do
    capabilities = %{"elicitation" => %{"form" => %{}}}
    a = url |> Client.new() |> Client.ready!(capabilities: capabilities)
    b = url |> Client.new() |> Client.ready!(capabilities: capabilities)

    {_a, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(a, "tools/call", elicit_task(10_000))

    # Session B cannot read the task of session A.
    #
    {_b, {200, _headers, %{"error" => error}}} =
      Client.request(b, "tasks/get", %{"taskId" => task_id})

    assert error["code"] == -32602

    # Session A watches its task on a tasks/result stream.
    #
    {a, response, sse} = Client.stream_request(a, "tasks/result", %{"taskId" => task_id})
    {request, sse} = wait_for_request(response, sse, "elicitation/create")

    # A forged answer on session B changes nothing.
    #
    {_b, {202, _headers, nil}} =
      Client.answer(b, request, %{"action" => "accept", "content" => %{"name" => "Eve"}})

    {_a, {200, _headers, %{"result" => %{"status" => "cancelled"}}}} =
      Client.request(a, "tasks/cancel", %{"taskId" => task_id})

    {notice, _sse} = wait_for_notice(response, sse, "notifications/cancelled")
    assert notice["params"]["requestId"] == request["id"]
  end

  # The timeout of a request that the test lets run out. It must be long
  # enough for the stream of `tasks/result` to attach first, also on a
  # loaded machine: a stream that attaches after the timeout never sees
  # the request. The test waits for the events, not for the clock.
  #
  @short_timeout 3_000

  @tag server: Servers.AuthorizedOutbound
  test "an answer after the timeout of the request is ignored", %{base_url: url} do
    capabilities = %{"elicitation" => %{"form" => %{}}}
    a = ready(url, "alice-token", capabilities)
    b = ready(url, "alice-token", capabilities)

    {_a, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(a, "tools/call", elicit_task(@short_timeout))

    {b, response, sse} = Client.stream_request(b, "tasks/result", %{"taskId" => task_id})
    result_id = b.next_id - 1

    {request, sse} = wait_for_request(response, sse, "elicitation/create")

    # The wait of the runner ends at its timeout: the client is told to
    # forget the request and the task goes back to working.
    #
    {notice, sse} = wait_for_notice(response, sse, "notifications/cancelled")
    assert notice["params"]["requestId"] == request["id"]

    %{params: %{"status" => "working"}} = wait_for_status(response, sse, task_id)

    assert %{"id" => ^result_id, "result" => %{"content" => [%{"text" => text}]}} =
             wait_for_answer(response, sse, result_id)

    assert text =~ ":timeout"

    # The late answer is ignored.
    #
    {_b, {202, _headers, nil}} =
      Client.answer(b, request, %{"action" => "accept", "content" => %{"name" => "Ana"}})
  end

  @tag server: Servers.AuthorizedOutbound
  test "tasks/cancel from session B ends the held request of the task", %{base_url: url} do
    capabilities = %{"elicitation" => %{"form" => %{}}}
    a = ready(url, "alice-token", capabilities)
    b = ready(url, "alice-token", capabilities)

    {_a, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(a, "tools/call", elicit_task(10_000))

    {b, response, sse} = Client.stream_request(b, "tasks/result", %{"taskId" => task_id})
    result_id = b.next_id - 1

    {request, sse} = wait_for_request(response, sse, "elicitation/create")

    {_b, {200, _headers, %{"result" => %{"status" => "cancelled"}}}} =
      Client.request(b, "tasks/cancel", %{"taskId" => task_id})

    {notice, sse} = wait_for_notice(response, sse, "notifications/cancelled")
    assert notice["params"]["requestId"] == request["id"]
    assert notice["params"]["_meta"] == related_task(task_id)

    assert %{"id" => ^result_id, "error" => error} = wait_for_answer(response, sse, result_id)
    assert error["code"] == -32800
    assert error["message"] == "task was cancelled"
  end

  @tag server: Servers.AuthorizedOutbound
  test "the log of a task reaches the tasks/result stream of another session", %{base_url: url} do
    a = ready(url, "alice-token")
    b = ready(url, "alice-token")

    {_b, {200, _headers, %{"result" => %{}}}} =
      Client.request(b, "logging/setLevel", %{"level" => "debug"})

    {_a, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(a, "tools/call", %{
        "name" => "log",
        "arguments" => %{"delay" => 500},
        "task" => %{}
      })

    {b, response, sse} = Client.stream_request(b, "tasks/result", %{"taskId" => task_id})
    result_id = b.next_id - 1

    {first, sse} = wait_for_notice(response, sse, "notifications/message")

    assert first["params"] == %{
             "level" => "debug",
             "data" => "step 1",
             "_meta" => related_task(task_id)
           }

    {second, sse} = wait_for_notice(response, sse, "notifications/message")

    assert second["params"]["level"] == "warning"
    assert second["params"]["data"] == %{"disk" => "92%"}
    assert second["params"]["_meta"] == related_task(task_id)

    assert %{"id" => ^result_id, "result" => %{"content" => [%{"text" => "log done"}]}} =
             wait_for_answer(response, sse, result_id)
  end

  @tag server: Servers.AuthorizedOutbound
  test "the tasks/result stream of a session with no log level gets no log but the result", %{
    base_url: url
  } do
    a = ready(url, "alice-token")
    b = ready(url, "alice-token")

    {_a, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(a, "tools/call", %{
        "name" => "log",
        "arguments" => %{"delay" => 500},
        "task" => %{}
      })

    {b, response, sse} = Client.stream_request(b, "tasks/result", %{"taskId" => task_id})
    result_id = b.next_id - 1

    # The session of the stream sent no logging/setLevel: the log of the
    # task never reaches the stream.
    #
    assert %{"id" => ^result_id, "result" => %{"content" => [%{"text" => "log done"}]}} =
             read_until_answer_without_log(response, sse, result_id)
  end

  @tag server: Servers.AuthorizedOutbound
  test "the progress of a task reaches the tasks/result stream of another session", %{
    base_url: url
  } do
    a = ready(url, "alice-token")
    b = ready(url, "alice-token")

    {_a, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(a, "tools/call", %{
        "name" => "progress",
        "arguments" => %{"delay" => 500},
        "_meta" => %{"progressToken" => "pt-1"},
        "task" => %{}
      })

    {b, response, sse} = Client.stream_request(b, "tasks/result", %{"taskId" => task_id})
    result_id = b.next_id - 1

    {first, sse} = wait_for_notice(response, sse, "notifications/progress")

    assert first["params"] == %{
             "progressToken" => "pt-1",
             "progress" => 1,
             "total" => 2,
             "message" => "step 1",
             "_meta" => related_task(task_id)
           }

    {second, sse} = wait_for_notice(response, sse, "notifications/progress")

    assert second["params"]["progressToken"] == "pt-1"
    assert second["params"]["progress"] == 2
    assert second["params"]["_meta"] == related_task(task_id)

    assert %{"id" => ^result_id, "result" => %{"content" => [%{"text" => "progress done"}]}} =
             wait_for_answer(response, sse, result_id)
  end

  @tag server: Servers.AuthorizedOutbound
  test "a stream whose client did not declare the capability gets no request", %{base_url: url} do
    a = ready(url, "alice-token", %{"elicitation" => %{"form" => %{}}})
    loud = ready(url, "alice-token", %{"elicitation" => %{"form" => %{}}})
    quiet = ready(url, "alice-token")

    {_a, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(a, "tools/call", elicit_task(@short_timeout))

    {_loud, loud_response, loud_sse} =
      Client.stream_request(loud, "tasks/result", %{"taskId" => task_id})

    # The stream of the client that declared the capability gets the held
    # request.
    #
    {request, _loud_sse} = wait_for_request(loud_response, loud_sse, "elicitation/create")
    assert %{"id" => "t." <> _rest} = request

    # The stream of the client that did not declare it attaches too: it
    # gets the status notifications and the result of the task, never the
    # request of the server.
    #
    {quiet, quiet_response, quiet_sse} =
      Client.stream_request(quiet, "tasks/result", %{"taskId" => task_id})

    quiet_id = quiet.next_id - 1

    assert %{"id" => ^quiet_id, "result" => %{"content" => [%{"text" => text}]}} =
             read_until_answer(quiet_response, quiet_sse, quiet_id)

    assert text =~ ":timeout"
  end

  defp ready(url, token) do
    url |> Client.new([{"authorization", "Bearer " <> token}]) |> Client.ready!()
  end

  # A session of the principal that declares capabilities of its own.
  #
  defp ready(url, token, capabilities) do
    url
    |> Client.new([{"authorization", "Bearer " <> token}])
    |> Client.ready!(capabilities: capabilities)
  end

  defp call_task(client, tool),
    do: Client.request(client, "tools/call", %{"name" => tool, "task" => %{}})

  # A task-augmented call of the tool that asks the client for an
  # elicitation in form mode.
  #
  defp elicit_task(timeout),
    do: %{
      "name" => "outbound",
      "arguments" => %{"feature" => "elicit_form", "timeout" => timeout},
      "task" => %{}
    }

  defp related_task(task_id),
    do: %{"io.modelcontextprotocol/related-task" => %{"taskId" => task_id}}

  # The events of an open stream until a request of the server with the
  # method arrives (a status notification can come first).
  #
  defp wait_for_request(resp, sse, method, tries \\ 100)

  defp wait_for_request(_resp, _sse, _method, 0),
    do: flunk("no request of the server arrived on the stream")

  defp wait_for_request(resp, sse, method, tries) do
    case next_event_quiet(resp, sse) do
      {:ok, event, sse} ->
        case JSON.decode!(event.data) do
          %{"method" => ^method, "id" => _id} = request -> {request, sse}
          _other -> wait_for_request(resp, sse, method, tries - 1)
        end

      :quiet ->
        wait_for_request(resp, sse, method, tries - 1)

      {:ended, _sse} ->
        flunk("the stream ended")
    end
  end

  # The events of an open stream until the response of the request that
  # opened it arrives (a status notification can come first). The events
  # after the response are of no use, so the state of the stream is lost.
  #
  defp wait_for_answer(resp, sse, result_id, tries \\ 100)

  defp wait_for_answer(_resp, _sse, _result_id, 0), do: flunk("no result arrived on the stream")

  defp wait_for_answer(resp, sse, result_id, tries) do
    case next_event_quiet(resp, sse) do
      {:ok, event, sse} ->
        case JSON.decode!(event.data) do
          %{"id" => ^result_id} = answer -> answer
          _other -> wait_for_answer(resp, sse, result_id, tries - 1)
        end

      :quiet ->
        wait_for_answer(resp, sse, result_id, tries - 1)

      {:ended, _sse} ->
        flunk("the stream ended")
    end
  end

  # The events of an open stream until a notification with the method
  # arrives (the other messages of the stream can come first).
  #
  defp wait_for_notice(resp, sse, method, tries \\ 100)

  defp wait_for_notice(_resp, _sse, method, 0),
    do: flunk("no #{method} arrived on the stream")

  defp wait_for_notice(resp, sse, method, tries) do
    case next_event_quiet(resp, sse) do
      {:ok, event, sse} ->
        case JSON.decode!(event.data) do
          %{"method" => ^method} = message -> {message, sse}
          _other -> wait_for_notice(resp, sse, method, tries - 1)
        end

      :quiet ->
        wait_for_notice(resp, sse, method, tries - 1)

      {:ended, _sse} ->
        flunk("the stream ended")
    end
  end

  # The events of an open stream until the response of the request that
  # opened it arrives. A log message on the stream fails: the session of
  # the stream set no log level.
  #
  defp read_until_answer_without_log(resp, sse, result_id, tries \\ 100)

  defp read_until_answer_without_log(_resp, _sse, _result_id, 0),
    do: flunk("no result arrived on the stream")

  defp read_until_answer_without_log(resp, sse, result_id, tries) do
    case next_event_quiet(resp, sse) do
      {:ok, event, sse} ->
        case JSON.decode!(event.data) do
          %{"method" => "notifications/message"} ->
            flunk("the stream carried a log message")

          %{"id" => ^result_id} = answer ->
            answer

          _other ->
            read_until_answer_without_log(resp, sse, result_id, tries - 1)
        end

      :quiet ->
        read_until_answer_without_log(resp, sse, result_id, tries - 1)

      {:ended, _sse} ->
        flunk("the stream ended")
    end
  end

  # The events of an open stream until the response of the request that
  # opened it arrives. A request of the server on the stream fails: the
  # test reads a stream that must carry no request.
  #
  defp read_until_answer(resp, sse, result_id, tries \\ 100)

  defp read_until_answer(_resp, _sse, _result_id, 0), do: flunk("no result arrived on the stream")

  defp read_until_answer(resp, sse, result_id, tries) do
    case next_event_quiet(resp, sse) do
      {:ok, event, sse} ->
        case JSON.decode!(event.data) do
          %{"method" => _method, "id" => _id} ->
            flunk("the stream carried a request of the server")

          %{"id" => ^result_id} = answer ->
            answer

          _other ->
            read_until_answer(resp, sse, result_id, tries - 1)
        end

      :quiet ->
        read_until_answer(resp, sse, result_id, tries - 1)

      {:ended, _sse} ->
        flunk("the stream ended")
    end
  end

  # The events of the GET stream until the status of the task arrives (a
  # replay of the log, or a priming event, can come first).
  #
  defp wait_for_status(resp, sse, task_id, tries \\ 100)

  defp wait_for_status(_resp, _sse, _task_id, 0), do: flunk("no status notification arrived")

  defp wait_for_status(resp, sse, task_id, tries) do
    case next_event_quiet(resp, sse) do
      {:ok, event, sse} ->
        case JSON.decode!(event.data) do
          %{"method" => "notifications/tasks/status", "params" => %{"taskId" => ^task_id}} =
              message ->
            %{params: message["params"], sse: sse}

          _other ->
            wait_for_status(resp, sse, task_id, tries - 1)
        end

      :quiet ->
        wait_for_status(resp, sse, task_id, tries - 1)

      {:ended, _sse} ->
        flunk("the GET stream ended")
    end
  end

  # The frames of an open stream (the priming events included, with the id
  # of each one) until a message that the predicate accepts arrives. The
  # answer of the request that opened the stream ends it: the frames
  # before it are the messages of the wait.
  #
  defp frames_until(resp, sse, pred, frames \\ [], tries \\ 400)

  defp frames_until(_resp, _sse, _pred, _frames, 0),
    do: flunk("the expected message never arrived on the stream")

  defp frames_until(resp, sse, pred, frames, tries) do
    case next_frame_quiet(resp, sse) do
      {:ok, %{data: ""} = frame, sse} ->
        frames_until(resp, sse, pred, [frame | frames], tries - 1)

      {:ok, frame, sse} ->
        message = JSON.decode!(frame.data)

        if pred.(message) do
          {:ok, Enum.reverse([frame | frames]), message, sse}
        else
          frames_until(resp, sse, pred, [frame | frames], tries - 1)
        end

      :quiet ->
        frames_until(resp, sse, pred, frames, tries - 1)

      {:ended, _sse} ->
        flunk("the stream ended before the expected message")
    end
  end

  defp next_frame_quiet(resp, sse) do
    Client.next_frame(resp, sse, 250)
  rescue
    _error -> :quiet
  end

  defp next_event_quiet(resp, sse) do
    Client.next_event(resp, sse, 250)
  rescue
    _error -> :quiet
  end

  defp wait_for_runner do
    assert Utils.eventually(fn ->
             Support.Entities.Tools.TaskSlowTest.last_runner_pid() != nil
           end)

    :ok
  end

  # The task goes away with the session: the new session gets -32602.
  #
  defp wait_for_error(client, task_id) do
    assert Utils.eventually(fn ->
             match?(
               {_client, {200, _headers, %{"error" => %{"code" => -32_602}}}},
               Client.request(client, "tasks/get", %{"taskId" => task_id})
             )
           end)

    :ok
  end
end
