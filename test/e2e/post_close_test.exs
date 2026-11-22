#
# The close of a `POST` stream at `sse_max_stream_ms` over a real
# connection: the stream writes the `retry:` hint and ends the response
# while the callback goes on. The client answers the request of the
# callback (an elicitation) or ends its task after the close, then
# resumes the stream with a `GET` and the last event id and gets the
# response of the request.
#
defmodule OzMcp.E2E.PostCloseTest do
  use OzMcp.E2ECase, async: true
  alias Support.Helpers.Utils
  alias Support.Servers

  @resource_url "https://mcp.example.com/mcp"
  @max_stream_ms 1_000
  @capabilities %{"elicitation" => %{"form" => %{}}}
  @answer_timeout 10_000

  @moduletag server: Servers.AuthorizedStreams
  @moduletag server_opts: %{resource_url: @resource_url, sse_max_stream_ms: @max_stream_ms}

  test "a tasks/result stream closes at sse_max_stream_ms and the client resumes for the outcome",
       %{base_url: url} do
    client = url |> Client.new(bearer("alice-token")) |> Client.ready!()

    {client, {200, _headers, %{"result" => %{"task" => task}}}} =
      Client.request(client, "tools/call", %{"name" => "task_slow", "task" => %{}})

    {client, resp1, sse1} =
      Client.stream_request(client, "tasks/result", %{"taskId" => task["taskId"]})

    result_id = client.next_id - 1

    # The connection ends at the retry hint, before the task finishes.
    #
    {last_id, sse1} = wait_for_retry(resp1, sse1)
    assert is_binary(last_id)

    {:ended, frames1, _sse} = Client.drain(resp1, sse1, 10_000)
    refute result_frame?(frames1)

    wait_for_runner()
    Support.Entities.Tools.TaskSlowTest.finish()

    # A GET with the last event id gets the outcome of the task and then
    # the stream ends.
    #
    {resp2, sse2} =
      Client.open_get(client, last_event_id: last_id, headers: bearer("alice-token"))

    {result, _sse} = wait_for_answer(resp2, sse2, result_id)

    assert %{
             "id" => ^result_id,
             "result" => %{"content" => [%{"type" => "text", "text" => "slow done"}]}
           } = result

    {:ended, _sse} = Client.next_frame(resp2, sse2)
  end

  test "a POST stream closes at sse_max_stream_ms and the client resumes after the answer",
       %{base_url: url} do
    client =
      url |> Client.new(bearer("alice-token")) |> Client.ready!(capabilities: @capabilities)

    {client, resp1, sse1} =
      Client.stream_request(client, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"feature" => "elicit_form", "timeout" => @answer_timeout}
      })

    request_id = client.next_id - 1

    {:ok, %{data: "", id: priming}, sse1} = Client.next_frame(resp1, sse1)
    assert priming =~ ~r/\A[^:]+:0\z/

    {:ok, elicitation, sse1} = Client.next_event(resp1, sse1)
    elicitation_message = JSON.decode!(elicitation.data)
    assert %{"method" => "elicitation/create"} = elicitation_message

    # The connection ends at the retry hint, before the client answers.
    #
    {last_id, sse1} = wait_for_retry(resp1, sse1, elicitation.id)
    assert is_binary(last_id)

    {:ended, frames1, _sse} = Client.drain(resp1, sse1, 10_000)
    refute result_frame?(frames1)

    {_client, {202, _headers, nil}} =
      Client.answer(client, elicitation_message, %{
        "action" => "accept",
        "content" => %{"name" => "Ada"}
      })

    # A GET with the last event id gets the response of the request and
    # then the stream ends.
    #
    {resp2, sse2} =
      Client.open_get(client, last_event_id: last_id, headers: bearer("alice-token"))

    {answer, _sse} = wait_for_answer(resp2, sse2, request_id)

    assert %{
             "id" => ^request_id,
             "result" => %{"content" => [%{"type" => "text", "text" => text}]}
           } = answer

    assert text =~ "\"Ada\""

    {:ended, _sse} = Client.next_frame(resp2, sse2)
  end

  defp bearer(token), do: [{"authorization", "Bearer " <> token}]

  defp result_frame?(frames) do
    Enum.any?(frames, fn frame ->
      frame.data != "" and String.contains?(frame.data, "\"result\"")
    end)
  end

  defp wait_for_retry(resp, sse, last_id \\ nil, tries \\ 10)

  defp wait_for_retry(_resp, _sse, _last_id, 0),
    do: flunk("no retry hint arrived on the stream")

  defp wait_for_retry(resp, sse, last_id, tries) do
    case Client.next_frame(resp, sse, 5_000) do
      {:ok, %{retry: retry}, sse} when not is_nil(retry) ->
        {last_id, sse}

      {:ok, frame, sse} ->
        wait_for_retry(resp, sse, frame.id || last_id, tries - 1)

      {:ended, _sse} ->
        flunk("the stream ended before the retry hint")
    end
  end

  defp wait_for_answer(resp, sse, request_id, tries \\ 40)

  defp wait_for_answer(_resp, _sse, _request_id, 0),
    do: flunk("no result arrived on the resumed stream")

  defp wait_for_answer(resp, sse, request_id, tries) do
    case Client.next_event(resp, sse, 5_000) do
      {:ok, event, sse} ->
        case JSON.decode!(event.data) do
          %{"id" => ^request_id} = answer -> {answer, sse}
          _other -> wait_for_answer(resp, sse, request_id, tries - 1)
        end

      {:ended, _sse} ->
        flunk("the resumed stream ended before the result")
    end
  end

  defp wait_for_runner do
    assert Utils.eventually(fn ->
             Support.Entities.Tools.TaskSlowTest.last_runner_pid() != nil
           end)

    :ok
  end
end
