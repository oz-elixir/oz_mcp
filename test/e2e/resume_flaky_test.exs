#
# The tests of `OzMcp.E2E.ResumeTest` that fail from time to time (a
# race or a time limit on a loaded machine). The tag `:flaky` is excluded
# by default (see `test/test_helper.exs`). Run them with
# `mix test --only flaky`.
#
defmodule OzMcp.E2E.ResumeFlakyTest do
  use OzMcp.E2ECase, async: true

  alias Support.Servers

  @capabilities %{
    "elicitation" => %{"form" => %{}, "url" => %{}},
    "sampling" => %{},
    "roots" => %{}
  }

  @answer_timeout 10_000

  @moduletag :flaky

  @tag server: Servers.Outbound
  @tag server_opts: %{sse_max_stream_ms: 500, sse_retry_ms: 250}
  test "a POST stream closes at sse_max_stream_ms and the client resumes", %{
    base_url: url
  } do
    client = url |> Client.new() |> Client.ready!(capabilities: @capabilities)

    {client, resp1, sse1} = call_outbound(client, "elicit_form")

    {:ok, elicitation, sse1} = Client.next_event(resp1, sse1)
    elicitation_message = JSON.decode!(elicitation.data)
    assert %{"method" => "elicitation/create"} = elicitation_message

    # At sse_max_stream_ms the connection closes with a retry hint, before
    # the client answers: the callback goes on.
    #
    {last_id, sse1} = wait_for_retry(resp1, sse1, elicitation.id)
    {:ended, frames1, _sse1} = Client.drain(resp1, sse1, 10_000)

    refute Enum.any?(frames1, fn frame ->
             frame.data != "" and String.contains?(frame.data, "\"result\"")
           end)

    {_client, {202, _headers, nil}} =
      Client.answer(client, elicitation_message, %{
        "action" => "accept",
        "content" => %{"name" => "Ada"}
      })

    # A GET with Last-Event-ID gets the response from the event log.
    #
    {resp2, sse2} = Client.open_get(client, last_event_id: last_id)

    {answer, _sse2} = wait_for_answer(resp2, sse2, 2)

    assert %{"id" => 2, "result" => %{"content" => [%{"text" => text}]}} = answer
    assert text =~ "\"Ada\""

    {:ended, _sse2} = Client.next_frame(resp2, sse2)
  end

  defp wait_for_retry(resp, sse, last_id, tries \\ 10)

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

  defp call_outbound(client, feature, opts \\ []) do
    Client.stream_request(
      client,
      "tools/call",
      %{
        "name" => "outbound",
        "arguments" => %{"feature" => feature, "timeout" => @answer_timeout}
      },
      opts
    )
  end
end
