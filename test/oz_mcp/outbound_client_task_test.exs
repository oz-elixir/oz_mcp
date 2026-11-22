defmodule OzMcp.OutboundClientTaskTest do
  use ExUnit.Case, async: true

  alias OzMcp.Auth.Principal
  alias OzMcp.Instance
  alias OzMcp.Outbound
  alias OzMcp.Outbound.ClientTask
  alias OzMcp.Outbound.ClientTask.Guard
  alias OzMcp.Session
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default
  @server Module.concat(@server_module, __MODULE__)

  setup do
    Utils.start_instance(@server_module, name: @server, client_tasks: true)
    :ok
  end

  defp capabilities do
    %{
      "sampling" => %{},
      "tasks" => %{"requests" => %{"sampling" => %{"createMessage" => %{}}}}
    }
  end

  defp cancel_capabilities do
    %{
      "sampling" => %{},
      "tasks" => %{
        "cancel" => %{},
        "requests" => %{"sampling" => %{"createMessage" => %{}}}
      }
    }
  end

  defp session(instance \\ @server), do: create_session(instance, capabilities())

  defp cancel_session(instance \\ @server),
    do: create_session(instance, cancel_capabilities())

  defp create_session(instance, capabilities) do
    Utils.create_session(instance,
      initialized: true,
      streams: [self()],
      client_capabilities: capabilities
    )
  end

  defp ctx(session_id, instance \\ @server) do
    %{
      instance: instance,
      server: @server_module,
      session_id: session_id,
      request_id: nil,
      principal: nil
    }
  end

  defp start_task(ctx, opts \\ []) do
    Task.async(fn ->
      Outbound.request_task(
        ctx,
        "sampling/createMessage",
        %{"messages" => [], "maxTokens" => 16},
        opts
      )
    end)
  end

  defp request(method) do
    {_event_id, message} = Utils.receive_event(5_000)
    assert message["method"] == method
    message
  end

  defp answer(session_id, message, result, instance \\ @server) do
    assert :ok = Outbound.deliver(instance, session_id, message["id"], result)
  end

  defp created(session_id, message, status, extra \\ %{}, instance \\ @server) do
    task = Map.merge(%{"taskId" => "c1", "status" => status}, extra)
    answer(session_id, message, {:ok, %{"task" => task}}, instance)
  end

  defp got(session_id, message, status, extra \\ %{}, instance \\ @server) do
    task = Map.merge(%{"taskId" => "c1", "status" => status}, extra)
    answer(session_id, message, {:ok, task}, instance)
  end

  defp sample_result, do: %{"role" => "assistant", "content" => [], "model" => "m"}

  defp serve_polls_until_cancel(session_id, polls) do
    {_event_id, message} = Utils.receive_event(5_000)

    case message["method"] do
      "tasks/get" ->
        got(session_id, message, "working")
        serve_polls_until_cancel(session_id, polls + 1)

      "tasks/cancel" ->
        {polls, message}
    end
  end

  defp serve_until_results(_session_id, 0, methods), do: methods

  defp serve_until_results(session_id, results_left, methods) do
    {_event_id, message} = Utils.receive_event(5_000)

    case message["method"] do
      "tasks/get" ->
        got(session_id, message, "completed")
        serve_until_results(session_id, results_left, ["tasks/get" | methods])

      "tasks/result" ->
        answer(session_id, message, {:ok, sample_result()})
        serve_until_results(session_id, results_left - 1, ["tasks/result" | methods])
    end
  end

  defp no_guard? do
    case Instance.whereis(@server, :calls) do
      {:ok, supervisor} -> Task.Supervisor.children(supervisor) == []
      :not_running -> true
    end
  end

  defp refute_cancel(timeout) do
    receive do
      {:oz_mcp_stream, _stream_id, {:event, _event_id, data}} ->
        message = data |> IO.iodata_to_binary() |> :json.decode()
        refute message["method"] == "tasks/cancel"
        refute_cancel(timeout)
    after
      timeout -> :ok
    end
  end

  test "a completed CreateTaskResult reads tasks/result" do
    session_id = session()
    task = start_task(ctx(session_id))

    create = request("sampling/createMessage")
    assert create["params"]["task"] == %{"ttl" => 120_000}
    created(session_id, create, "completed")

    result = request("tasks/result")
    assert result["params"] == %{"taskId" => "c1"}
    answer(session_id, result, {:ok, sample_result()})

    assert Task.await(task, 30_000) == {:ok, sample_result()}
  end

  test "a task value of the params wins over the ttl option" do
    session_id = session()

    task =
      Task.async(fn ->
        Outbound.request_task(
          ctx(session_id),
          "sampling/createMessage",
          %{"messages" => [], "maxTokens" => 16, task: %{ttl: 5}},
          ttl: 9
        )
      end)

    create = request("sampling/createMessage")
    assert create["params"]["task"] == %{"ttl" => 5}

    created(session_id, create, "completed")
    answer(session_id, request("tasks/result"), {:ok, sample_result()})

    assert Task.await(task, 30_000) == {:ok, sample_result()}
  end

  test "params with no task get the ttl of the options" do
    session_id = session()
    task = start_task(ctx(session_id), ttl: 9)

    create = request("sampling/createMessage")
    assert create["params"]["task"] == %{"ttl" => 9}

    created(session_id, create, "completed")
    answer(session_id, request("tasks/result"), {:ok, sample_result()})

    assert Task.await(task, 30_000) == {:ok, sample_result()}
  end

  test "working, working and completed: two tasks/get and one tasks/result" do
    session_id = session()
    task = start_task(ctx(session_id), poll_interval: 100)

    created(session_id, request("sampling/createMessage"), "working")

    got(session_id, request("tasks/get"), "working")
    got(session_id, request("tasks/get"), "completed")

    result = request("tasks/result")
    answer(session_id, result, {:ok, sample_result()})

    assert Task.await(task, 30_000) == {:ok, sample_result()}
  end

  test "a pollInterval of 1 ms is raised to the floor" do
    session_id = session()
    task = start_task(ctx(session_id))

    create = request("sampling/createMessage")
    start = System.monotonic_time(:millisecond)
    created(session_id, create, "working", %{"pollInterval" => 1})

    get = request("tasks/get")
    elapsed = System.monotonic_time(:millisecond) - start
    assert elapsed >= 80

    got(session_id, get, "completed")
    answer(session_id, request("tasks/result"), {:ok, sample_result()})

    assert Task.await(task, 30_000) == {:ok, sample_result()}
  end

  test "a pollInterval that is not an integer is ignored" do
    session_id = session()
    task = start_task(ctx(session_id), poll_interval: 300)

    create = request("sampling/createMessage")
    start = System.monotonic_time(:millisecond)
    created(session_id, create, "working", %{"pollInterval" => "100"})

    get = request("tasks/get")
    elapsed = System.monotonic_time(:millisecond) - start
    assert elapsed >= 250

    got(session_id, get, "completed")
    answer(session_id, request("tasks/result"), {:ok, sample_result()})

    assert Task.await(task, 30_000) == {:ok, sample_result()}
  end

  test "a failed task reads tasks/result and returns its error" do
    session_id = session()
    task = start_task(ctx(session_id), poll_interval: 100)

    created(session_id, request("sampling/createMessage"), "working")
    got(session_id, request("tasks/get"), "failed")

    error = %{"code" => -32603, "message" => "the model failed"}
    answer(session_id, request("tasks/result"), {:error, error})

    assert Task.await(task, 30_000) == {:error, {:rpc_error, error}}
  end

  test "a cancelled task gives the task id and reads no result" do
    session_id = session()
    task = start_task(ctx(session_id), poll_interval: 100)

    created(session_id, request("sampling/createMessage"), "working")
    got(session_id, request("tasks/get"), "cancelled")

    assert Task.await(task, 30_000) == {:error, {:client_task_cancelled, "c1"}}
    refute_receive {:oz_mcp_stream, _, _}, 100
  end

  test "input_required calls tasks/result at once and its answer is final" do
    session_id = session()
    task = start_task(ctx(session_id))

    created(session_id, request("sampling/createMessage"), "input_required")

    result = request("tasks/result")
    answer(session_id, result, {:ok, sample_result()})

    assert Task.await(task, 30_000) == {:ok, sample_result()}
  end

  test "input_required: a tasks/result that times out goes back to tasks/get" do
    instance = Module.concat(@server, "Short")

    Utils.start_instance(@server_module,
      name: instance,
      client_request_timeout_ms: 50,
      client_tasks: true
    )

    session_id = session(instance)
    task = start_task(ctx(session_id, instance), poll_interval: 100)

    created(session_id, request("sampling/createMessage"), "input_required", %{}, instance)

    # The tasks/result gets no answer and ends at the inner timeout.
    #
    assert request("tasks/result")["params"] == %{"taskId" => "c1"}

    {_event_id, cancelled} = Utils.receive_event(5_000)
    assert cancelled["method"] == "notifications/cancelled"

    get = request("tasks/get")
    assert get["params"] == %{"taskId" => "c1"}

    got(session_id, get, "completed", %{}, instance)
    answer(session_id, request("tasks/result"), {:ok, sample_result()}, instance)

    assert Task.await(task, 30_000) == {:ok, sample_result()}
  end

  test "a bad CreateTaskResult is an invalid response" do
    session_id = session()
    task = start_task(ctx(session_id))

    answer(session_id, request("sampling/createMessage"), {:ok, %{}})

    assert Task.await(task, 30_000) == {:error, {:invalid_response, %{}}}
  end

  test "a bad tasks/get answer is an invalid response" do
    session_id = session()
    task = start_task(ctx(session_id), poll_interval: 100)

    created(session_id, request("sampling/createMessage"), "working")
    wrong = %{"taskId" => "c1", "status" => "weird"}
    answer(session_id, request("tasks/get"), {:ok, wrong})

    assert Task.await(task, 30_000) == {:error, {:invalid_response, wrong}}
  end

  test "no answer to tasks/get before the deadline gives a timeout" do
    session_id = session()
    task = start_task(ctx(session_id), timeout: 200, poll_interval: 100)

    created(session_id, request("sampling/createMessage"), "working")

    assert Task.await(task, 30_000) == {:error, :timeout}
  end

  test "a create that times out starts no guard and sends no tasks/cancel" do
    session_id = cancel_session()
    task = start_task(ctx(session_id), timeout: 300)

    assert request("sampling/createMessage")["method"] == "sampling/createMessage"

    assert Task.await(task, 30_000) == {:error, :timeout}
    assert no_guard?()
    refute_cancel(200)
  end

  test "the deadline ends during the wait of a large pollInterval" do
    session_id = session()
    task = start_task(ctx(session_id), timeout: 150)

    created(session_id, request("sampling/createMessage"), "working", %{"pollInterval" => 60_000})

    assert Task.await(task, 30_000) == {:error, :timeout}
    refute_receive {:oz_mcp_stream, _, _}, 300
  end

  test "timeout :infinity sends no ttl and the flow ends normally" do
    session_id = session()
    task = start_task(ctx(session_id), timeout: :infinity)

    create = request("sampling/createMessage")
    assert create["params"]["task"] == %{}
    created(session_id, create, "completed")

    answer(session_id, request("tasks/result"), {:ok, sample_result()})

    assert Task.await(task, 30_000) == {:ok, sample_result()}
  end

  test "a GET stream that closes between two polls does not end the loop" do
    session_id = session()
    task = start_task(ctx(session_id), poll_interval: 100)

    created(session_id, request("sampling/createMessage"), "working", %{"pollInterval" => 100})
    assert :ok = Session.close_stream(@server, session_id, self())

    # Let the next poll fail with :no_stream, then open the stream again.
    #
    Process.sleep(150)
    assert {:ok, _stream} = Session.open_stream(@server, session_id, :get, self(), nil)

    get = request("tasks/get")
    got(session_id, get, "completed")
    answer(session_id, request("tasks/result"), {:ok, sample_result()})

    assert Task.await(task, 30_000) == {:ok, sample_result()}
  end

  test "a completed task retries tasks/result after a GET stream closes" do
    session_id = session()
    task = start_task(ctx(session_id), poll_interval: 100)

    create = request("sampling/createMessage")
    assert :ok = Session.close_stream(@server, session_id, self())

    # tasks/result fails with :no_stream and the loop goes back to tasks/get.
    #
    created(session_id, create, "completed")
    Process.sleep(150)
    assert {:ok, _stream} = Session.open_stream(@server, session_id, :get, self(), nil)

    get = request("tasks/get")
    got(session_id, get, "completed")
    answer(session_id, request("tasks/result"), {:ok, sample_result()})

    assert Task.await(task, 30_000) == {:ok, sample_result()}
  end

  test "a failed task retries tasks/result after a GET stream closes" do
    session_id = session()
    task = start_task(ctx(session_id), poll_interval: 100)

    create = request("sampling/createMessage")
    assert :ok = Session.close_stream(@server, session_id, self())

    created(session_id, create, "failed")
    Process.sleep(150)
    assert {:ok, _stream} = Session.open_stream(@server, session_id, :get, self(), nil)

    got(session_id, request("tasks/get"), "failed")

    error = %{"code" => -32603, "message" => "the model failed"}
    answer(session_id, request("tasks/result"), {:error, error})

    assert Task.await(task, 30_000) == {:error, {:rpc_error, error}}
  end

  test "a terminal task with no GET stream gives a timeout at the deadline" do
    session_id = cancel_session()
    task = start_task(ctx(session_id), timeout: 300, poll_interval: 100)

    create = request("sampling/createMessage")
    assert :ok = Session.close_stream(@server, session_id, self())

    created(session_id, create, "completed")

    assert Task.await(task, 30_000) == {:error, :timeout}
    refute_receive {:oz_mcp_stream, _, _}, 150
  end

  test "a hint wakes the poll before the interval" do
    session_id = session()
    task = start_task(ctx(session_id), poll_interval: 60_000)

    created(session_id, request("sampling/createMessage"), "working", %{
      "pollInterval" => 60_000
    })

    key = {:client_task, {:session, session_id}, "c1"}
    assert Utils.eventually(fn -> Registry.lookup(Instance.topics(@server), key) != [] end)

    start = System.monotonic_time(:millisecond)
    assert :ok = ClientTask.hint(ctx(session_id), "c1")

    get = request("tasks/get")
    assert System.monotonic_time(:millisecond) - start < 1_000

    got(session_id, get, "completed")
    answer(session_id, request("tasks/result"), {:ok, sample_result()})

    assert Task.await(task, 30_000) == {:ok, sample_result()}
  end

  test "a pollInterval over the ceiling does not crash the loop" do
    session_id = session()
    task = start_task(ctx(session_id), timeout: :infinity)

    created(session_id, request("sampling/createMessage"), "working", %{
      "pollInterval" => 5_000_000_000
    })

    key = {:client_task, {:session, session_id}, "c1"}
    assert Utils.eventually(fn -> Registry.lookup(Instance.topics(@server), key) != [] end)

    start = System.monotonic_time(:millisecond)
    assert :ok = ClientTask.hint(ctx(session_id), "c1")

    get = request("tasks/get")
    assert System.monotonic_time(:millisecond) - start < 1_000

    got(session_id, get, "completed")
    answer(session_id, request("tasks/result"), {:ok, sample_result()})

    assert Task.await(task, 30_000) == {:ok, sample_result()}
  end

  test "a poll_interval option over the ceiling does not crash the loop" do
    session_id = session()

    task =
      start_task(ctx(session_id), timeout: :infinity, poll_interval: 5_000_000_000)

    created(session_id, request("sampling/createMessage"), "working")

    key = {:client_task, {:session, session_id}, "c1"}
    assert Utils.eventually(fn -> Registry.lookup(Instance.topics(@server), key) != [] end)

    start = System.monotonic_time(:millisecond)
    assert :ok = ClientTask.hint(ctx(session_id), "c1")

    get = request("tasks/get")
    assert System.monotonic_time(:millisecond) - start < 1_000

    got(session_id, get, "completed")
    answer(session_id, request("tasks/result"), {:ok, sample_result()})

    assert Task.await(task, 30_000) == {:ok, sample_result()}
  end

  test "a hint for another owner does not wake the loop" do
    session_id = session()
    alice = Principal.new!(subject: "alice")
    bob = Principal.new!(subject: "bob")
    alice_ctx = Map.put(ctx(session_id), :principal, alice)
    task = start_task(alice_ctx, poll_interval: 60_000)

    created(session_id, request("sampling/createMessage"), "working", %{
      "pollInterval" => 60_000
    })

    key = {:client_task, {:principal, {nil, "alice"}}, "c1"}
    assert Utils.eventually(fn -> Registry.lookup(Instance.topics(@server), key) != [] end)

    assert :ok = ClientTask.hint(Map.put(ctx(session_id), :principal, bob), "c1")
    refute_receive {:oz_mcp_stream, _, _}, 150

    assert :ok = ClientTask.hint(alice_ctx, "c1")

    got(session_id, request("tasks/get"), "completed")
    answer(session_id, request("tasks/result"), {:ok, sample_result()})

    assert Task.await(task, 30_000) == {:ok, sample_result()}
  end

  test "the pollInterval of the client wins over the call option" do
    session_id = session()
    task = start_task(ctx(session_id), poll_interval: 60_000)

    create = request("sampling/createMessage")
    created(session_id, create, "working", %{"pollInterval" => 100})

    # The wait of `request/1` is the bound: the option would let the
    # request come after 60 seconds.
    #
    get = request("tasks/get")

    got(session_id, get, "completed")
    answer(session_id, request("tasks/result"), {:ok, sample_result()})

    assert Task.await(task, 30_000) == {:ok, sample_result()}
  end

  test "the time limit starts before the create request" do
    session_id = cancel_session()
    task = start_task(ctx(session_id), timeout: 2_000, poll_interval: 200)

    create = request("sampling/createMessage")

    # The create is answered when most of the limit is used. The flow polls
    # at most until the end of the limit, so it asks for the status a few
    # times. If the limit started at the answer, the flow would poll for
    # a whole limit (about ten times). The test counts the polls and does
    # not measure the time: a slow machine makes the flow poll less, not more.
    #
    Process.sleep(1_200)
    created(session_id, create, "working", %{"pollInterval" => 200})

    {polls, cancel} = serve_polls_until_cancel(session_id, 0)

    assert cancel["params"] == %{"taskId" => "c1"}
    assert polls <= 6
    assert Task.await(task, 30_000) == {:error, :timeout}
  end

  test "two waiters of one owner with the same client task id both get the hint" do
    session_id = session()
    first = start_task(ctx(session_id), poll_interval: 60_000)
    second = start_task(ctx(session_id), poll_interval: 60_000)

    created(session_id, request("sampling/createMessage"), "working", %{
      "pollInterval" => 60_000
    })

    created(session_id, request("sampling/createMessage"), "working", %{
      "pollInterval" => 60_000
    })

    key = {:client_task, {:session, session_id}, "c1"}

    assert Utils.eventually(fn ->
             length(Registry.lookup(Instance.topics(@server), key)) == 2
           end)

    assert :ok = ClientTask.hint(ctx(session_id), "c1")

    # The two waiters run at the same time: a waiter can ask for the result
    # before the other one asks for the status. The test serves the requests
    # in the order they come and counts them.
    #
    methods = serve_until_results(session_id, 2, [])
    assert Enum.sort(methods) == ["tasks/get", "tasks/get", "tasks/result", "tasks/result"]

    assert Task.await(first, 30_000) == {:ok, sample_result()}
    assert Task.await(second, 30_000) == {:ok, sample_result()}
  end

  describe "tasks/cancel of the client task" do
    test "a waiter that stops sends one tasks/cancel for the client task" do
      session_id = cancel_session()
      task = start_task(ctx(session_id), poll_interval: 60_000)

      created(session_id, request("sampling/createMessage"), "working", %{
        "pollInterval" => 60_000
      })

      key = {:client_task, {:session, session_id}, "c1"}
      assert Utils.eventually(fn -> Registry.lookup(Instance.topics(@server), key) != [] end)

      Task.shutdown(task, :brutal_kill)
      refute Process.alive?(task.pid)

      cancel = request("tasks/cancel")
      assert cancel["params"] == %{"taskId" => "c1"}
      refute_receive {:oz_mcp_stream, _, _}, 150
      assert Utils.eventually(fn -> no_guard?() end)
    end

    test "a waiter that times out sends one tasks/cancel and does not wait for its answer" do
      session_id = cancel_session()
      start = System.monotonic_time(:millisecond)
      task = start_task(ctx(session_id), timeout: 200)

      created(session_id, request("sampling/createMessage"), "working", %{
        "pollInterval" => 60_000
      })

      assert Task.await(task, 30_000) == {:error, :timeout}
      assert System.monotonic_time(:millisecond) - start < 1_000

      cancel = request("tasks/cancel")
      assert cancel["params"] == %{"taskId" => "c1"}
      refute_receive {:oz_mcp_stream, _, _}, 150
    end

    test "a bad tasks/get answer sends one tasks/cancel" do
      session_id = cancel_session()
      task = start_task(ctx(session_id), poll_interval: 100)

      created(session_id, request("sampling/createMessage"), "working")
      wrong = %{"taskId" => "c1", "status" => "weird"}
      answer(session_id, request("tasks/get"), {:ok, wrong})

      assert Task.await(task, 30_000) == {:error, {:invalid_response, wrong}}

      cancel = request("tasks/cancel")
      assert cancel["params"] == %{"taskId" => "c1"}
      refute_receive {:oz_mcp_stream, _, _}, 150
      assert Utils.eventually(fn -> no_guard?() end)
    end

    test "a normal end sends no tasks/cancel and the guard ends" do
      session_id = cancel_session()
      task = start_task(ctx(session_id))

      created(session_id, request("sampling/createMessage"), "completed")
      answer(session_id, request("tasks/result"), {:ok, sample_result()})

      assert Task.await(task, 30_000) == {:ok, sample_result()}
      refute_receive {:oz_mcp_stream, _, _}, 150
      assert Utils.eventually(fn -> no_guard?() end)
    end

    test "a cancelled client task sends no tasks/cancel and the guard ends" do
      session_id = cancel_session()
      task = start_task(ctx(session_id), poll_interval: 100)

      created(session_id, request("sampling/createMessage"), "working")
      got(session_id, request("tasks/get"), "cancelled")

      assert Task.await(task, 30_000) == {:error, {:client_task_cancelled, "c1"}}
      refute_receive {:oz_mcp_stream, _, _}, 150
      assert Utils.eventually(fn -> no_guard?() end)
    end

    test "a client with no tasks.cancel capability gets no cancel and the guard ends" do
      session_id = session()
      task = start_task(ctx(session_id), poll_interval: 100)

      created(session_id, request("sampling/createMessage"), "working")
      wrong = %{"taskId" => "c1", "status" => "weird"}
      answer(session_id, request("tasks/get"), {:ok, wrong})

      assert Task.await(task, 30_000) == {:error, {:invalid_response, wrong}}
      refute_receive {:oz_mcp_stream, _, _}, 150
      assert Utils.eventually(fn -> no_guard?() end)
    end

    test "an error of tasks/cancel does not crash the guard and logs one line" do
      session_id = cancel_session()

      log =
        Utils.capture_log([level: :debug], fn ->
          task = start_task(ctx(session_id), poll_interval: 100)

          created(session_id, request("sampling/createMessage"), "working")
          wrong = %{"taskId" => "c1", "status" => "weird"}
          answer(session_id, request("tasks/get"), {:ok, wrong})

          assert Task.await(task, 30_000) == {:error, {:invalid_response, wrong}}

          error = %{"code" => -32_602, "message" => "the task is gone"}
          answer(session_id, request("tasks/cancel"), {:error, error})

          assert Utils.eventually(fn -> no_guard?() end)
        end)

      assert log =~ "client task cancel: rpc_error"
      refute log =~ "the task is gone"
    end

    test "a cancel for a server task that is gone goes on the GET stream" do
      session_id = cancel_session()
      ctx = Map.put(ctx(session_id), :task_id, "gone")

      guard = Guard.start(ctx, "c1", self())
      assert is_pid(guard)

      assert :ok = Guard.stop(guard, :cancel)

      cancel = request("tasks/cancel")
      assert cancel["params"] == %{"taskId" => "c1"}
      assert Utils.eventually(fn -> no_guard?() end)
    end
  end

  describe "client_tasks: false (default)" do
    setup do
      name = Module.concat(@server, "Off")
      Utils.start_instance(@server_module, name: name)
      %{off: name}
    end

    test "request_task gives :client_tasks_disabled and sends nothing", %{off: off} do
      session_id = session(off)
      ctx = ctx(session_id, off)

      assert {:error, :client_tasks_disabled} =
               Outbound.request_task(ctx, "sampling/createMessage", %{"messages" => []})

      assert SessionProbe.pending_outbound_ids(off, session_id) == []
      refute_receive {:oz_mcp_stream, _, _}, 100
    end
  end
end
