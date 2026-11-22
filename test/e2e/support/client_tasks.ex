#
# A scripted client for the requests of a client task. The script is a
# list of steps:
#
#   * `{:create, task}` - answer a task-augmented request with a
#     `CreateTaskResult` that holds `task`;
#   * `{:plain, result}` - answer a plain request (no `task` key) with
#     `result`;
#   * `{:get, status}` or `{:get, status, extra}` - answer `tasks/get`
#     with the status and the extra keys;
#   * `{:result, result}` - answer `tasks/result` with `result`;
#   * `{:result_error, error}` - answer `tasks/result` with a JSON-RPC
#     error;
#   * `{:notify, task_id, status}` - send `notifications/tasks/status`;
#   * `:expect_cancel` - answer `tasks/cancel` with a cancelled task.
#
# The notifications of the server are skipped while the script waits for
# a request.
#
defmodule OzMcp.E2E.ClientTasks do
  import ExUnit.Assertions

  alias OzMcp.E2E.Client

  @task_methods ["sampling/createMessage", "elicitation/create"]
  @timeout 5_000

  @spec run(Client.t(), Req.Response.t(), map(), list()) :: {Client.t(), map()}
  def run(%Client{} = client, response, sse, script) do
    state = %{client: client, response: response, sse: sse, task_id: nil}
    state = Enum.reduce(script, state, &step/2)
    {state.client, state.sse}
  end

  # The next request of the server on the stream. The notifications are
  # skipped. A test uses it when the flow needs more than one answer.
  #
  @spec request(Req.Response.t(), map(), pos_integer()) :: {map(), map()}
  def request(response, sse, timeout \\ @timeout) do
    case Client.next_event(response, sse, timeout) do
      {:ok, event, sse} ->
        case JSON.decode!(event.data) do
          %{"method" => method, "id" => _id} = request when is_binary(method) ->
            {request, sse}

          _notification ->
            request(response, sse, timeout)
        end

      {:ended, _sse} ->
        flunk("the stream ended before the expected request of the server")
    end
  end

  defp step({:create, task}, state) do
    {request, sse} = await_any(state.response, state.sse, @task_methods)
    assert is_map(request["params"]["task"])

    task = with_defaults(task)
    {client, _answer} = Client.answer(state.client, request, %{"task" => task})

    %{state | client: client, sse: sse, task_id: task["taskId"]}
  end

  defp step({:plain, result}, state) do
    {request, sse} = await_any(state.response, state.sse, @task_methods)
    refute Map.has_key?(request["params"], "task")

    {client, _answer} = Client.answer(state.client, request, result)
    %{state | client: client, sse: sse}
  end

  defp step({:get, status}, state), do: step({:get, status, %{}}, state)

  defp step({:get, status, extra}, state) do
    {request, sse} = await(state.response, state.sse, "tasks/get")
    assert request["params"]["taskId"] == state.task_id

    {client, _answer} = Client.answer(state.client, request, task(state.task_id, status, extra))
    %{state | client: client, sse: sse}
  end

  defp step({:result, result}, state) do
    {request, sse} = await(state.response, state.sse, "tasks/result")
    assert request["params"]["taskId"] == state.task_id

    {client, _answer} = Client.answer(state.client, request, result)
    %{state | client: client, sse: sse}
  end

  defp step({:result_error, error}, state) do
    {request, sse} = await(state.response, state.sse, "tasks/result")
    assert request["params"]["taskId"] == state.task_id

    {client, _answer} = answer_error(state.client, request, error)
    %{state | client: client, sse: sse}
  end

  defp step({:notify, task_id, status}, state) do
    {client, {202, _headers, nil}} =
      Client.notify(state.client, "notifications/tasks/status", %{
        "taskId" => task_id,
        "status" => status
      })

    %{state | client: client}
  end

  defp step(:expect_cancel, state) do
    {request, sse} = await(state.response, state.sse, "tasks/cancel")
    assert request["params"]["taskId"] == state.task_id

    {client, _answer} =
      Client.answer(state.client, request, task(state.task_id, "cancelled", %{}))

    %{state | client: client, sse: sse}
  end

  defp await_any(response, sse, methods) do
    {request, sse} = request(response, sse)

    if request["method"] in methods do
      {request, sse}
    else
      await_any(response, sse, methods)
    end
  end

  defp await(response, sse, method) do
    {request, sse} = request(response, sse)

    if request["method"] == method do
      {request, sse}
    else
      await(response, sse, method)
    end
  end

  defp answer_error(client, request, error) do
    Client.post(client, %{"jsonrpc" => "2.0", "id" => request["id"], "error" => error})
  end

  defp with_defaults(task) do
    Map.merge(
      %{
        "createdAt" => "2026-01-01T00:00:00Z",
        "lastUpdatedAt" => "2026-01-01T00:00:00Z",
        "ttl" => 60_000
      },
      task
    )
  end

  defp task(task_id, status, extra) do
    with_defaults(Map.merge(%{"taskId" => task_id, "status" => status}, extra))
  end
end
