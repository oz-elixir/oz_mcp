#
# The authorization of the MCP endpoint over a real connection: a request
# with no token, with an expired token and with a token for another
# audience gets `401` and the challenge of RFC 9728 in the
# `WWW-Authenticate` header, a call that needs another scope gets `403`
# with the step-up union of the scopes and the Protected Resource
# Metadata document is served at its well-known URL.
#
defmodule OzMcp.E2E.AuthTest do
  use OzMcp.E2ECase, async: true

  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  @moduletag server: Servers.Authorized
  @moduletag server_opts: %{resource_url: "https://mcp.example.com/mcp"}

  @resource_url "https://mcp.example.com/mcp"
  @metadata_url "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"
  @metadata_path "/.well-known/oauth-protected-resource/mcp"

  test "a request with no token gets 401 and the bare challenge", %{base_url: url} do
    {_client, {401, headers, body}} = Client.new(url) |> Client.initialize()

    assert %{"error" => %{"code" => -32010, "message" => "unauthorized"}} = body
    assert get_header(headers, "mcp-session-id") == nil

    challenge = get_header(headers, "www-authenticate")
    assert challenge == ~s(Bearer scope="files:read", resource_metadata="#{@metadata_url}")
  end

  test "a request with an expired token gets 401 with the invalid_token challenge", %{
    base_url: url
  } do
    #
    # The token of the test holds a number of its own: the verifier holds
    # the expiry time under the token, so no other test sees it.
    #
    token = Support.Auth.Default.register_token()
    Support.Auth.Default.expire_at(token, System.system_time(:second) - 10)

    {_client, {401, headers, body}} =
      Client.new(url, bearer(token)) |> Client.initialize()

    assert %{"error" => %{"code" => -32010, "message" => "unauthorized"}} = body
    assert get_header(headers, "mcp-session-id") == nil

    challenge = get_header(headers, "www-authenticate")
    assert challenge =~ ~s(error="invalid_token")
    assert challenge =~ ~s(error_description="token expired")
    assert challenge =~ ~s(scope="files:read")
    assert challenge =~ ~s(resource_metadata="#{@metadata_url}")
  end

  test "a request with a token for another audience gets 401", %{base_url: url} do
    {_client, {401, headers, body}} =
      Client.new(url, bearer("other-audience")) |> Client.initialize()

    assert %{"error" => %{"code" => -32010, "message" => "unauthorized"}} = body
    assert get_header(headers, "mcp-session-id") == nil

    challenge = get_header(headers, "www-authenticate")
    assert challenge =~ ~s(error="invalid_token")
    assert challenge =~ ~s(error_description="token audience mismatch")
    assert challenge =~ ~s(scope="files:read")
    assert challenge =~ ~s(resource_metadata="#{@metadata_url}")
  end

  test "a token for this resource creates a session", %{base_url: url} do
    client = url |> Client.new(bearer("alice-token")) |> Client.ready!()
    assert is_binary(client.session_id) and client.session_id != ""

    {_client, {200, _headers, %{"result" => result}}} =
      Client.request(client, "tools/call", %{"name" => "get_time"})

    assert [%{"type" => "text", "text" => _}] = result["content"]
  end

  test "a call that needs another scope gets 403 with the step-up union", %{base_url: url} do
    client = url |> Client.new(bearer("alice-token")) |> Client.ready!()

    {_client, {403, headers, body}} =
      Client.request(client, "tools/call", %{"name" => "get_date"})

    assert %{"error" => %{"code" => -32011, "message" => "insufficient scope"}} = body

    # The scope of the challenge is the union of the scopes the principal
    # holds (files:read) and the needed scopes (files:read, files:write):
    # a client that asks a new token with this list keeps the scopes it
    # had.
    #
    challenge = get_header(headers, "www-authenticate")
    assert challenge =~ ~s(error="insufficient_scope")
    assert challenge =~ ~s(error_description="write permission needed")
    assert challenge =~ ~s(scope="files:read files:write")
    assert challenge =~ ~s(resource_metadata="#{@metadata_url}")
  end

  test "the metadata document is served at its well-known URL", %{base_url: url} do
    root = String.replace_trailing(url, "/mcp", "")

    response = Req.get!(root <> @metadata_path, retry: false)

    assert response.status == 200
    assert Req.Response.get_header(response, "access-control-allow-origin") == ["*"]

    assert response.body == %{
             "resource" => @resource_url,
             "authorization_servers" => ["https://auth.example.com"],
             "scopes_supported" => ["files:read", "files:write"],
             "bearer_methods_supported" => ["header"],
             "resource_name" => "Test MCP server",
             "resource_documentation" => "https://docs.example.com/mcp"
           }

    # Another path under the well-known prefix is not the document.
    #
    response = Req.get!(root <> "/.well-known/oauth-protected-resource/other", retry: false)
    assert response.status == 404
  end

  test "a request that passes gives no refusal event", %{base_url: url, instance: instance} do
    ref = TelemetryCapture.attach()

    {_client, {200, _headers, %{"result" => %{}}}} =
      Client.new(url, bearer("alice-token")) |> Client.initialize()

    refute any_auth_event?(TelemetryCapture.drain(ref, instance))
  end

  test "a request with no token gives one refusal event", %{base_url: url, instance: instance} do
    ref = TelemetryCapture.attach()

    {_client, {401, _headers, _body}} = Client.new(url) |> Client.initialize()

    assert_auth_event(
      TelemetryCapture.drain(ref, instance),
      instance,
      :authenticate,
      :missing_token
    )
  end

  test "an expired token gives one refusal event", %{base_url: url, instance: instance} do
    ref = TelemetryCapture.attach()

    # The token of the test holds a number of its own: the verifier holds
    # the expiry time under the token, so no other test sees it.
    #
    token = Support.Auth.Default.register_token()
    Support.Auth.Default.expire_at(token, System.system_time(:second) - 10)

    {_client, {401, _headers, _body}} =
      Client.new(url, bearer(token)) |> Client.initialize()

    assert_auth_event(
      TelemetryCapture.drain(ref, instance),
      instance,
      :authenticate,
      :token_expired
    )
  end

  test "a token for another audience gives one refusal event", %{
    base_url: url,
    instance: instance
  } do
    ref = TelemetryCapture.attach()

    {_client, {401, _headers, _body}} =
      Client.new(url, bearer("other-audience")) |> Client.initialize()

    assert_auth_event(
      TelemetryCapture.drain(ref, instance),
      instance,
      :authenticate,
      :audience_mismatch
    )
  end

  test "a malformed credential gives one refusal event", %{base_url: url, instance: instance} do
    ref = TelemetryCapture.attach()

    body =
      :json.encode(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
      |> IO.iodata_to_binary()

    {_client, {400, _headers, _body}} =
      Client.new(url)
      |> Client.send_raw(:post, body,
        with_defaults: false,
        headers: [
          {"content-type", "application/json"},
          {"authorization", "Bearer alice-token"},
          {"authorization", "Bearer bob-token"}
        ]
      )

    assert_auth_event(
      TelemetryCapture.drain(ref, instance),
      instance,
      :authenticate,
      :invalid_request
    )
  end

  test "a call that the callback refuses for the scopes gives one refusal event", %{
    base_url: url,
    instance: instance
  } do
    ref = TelemetryCapture.attach()

    client = url |> Client.new(bearer("alice-token")) |> Client.ready!()

    {_client, {403, _headers, %{"error" => %{"code" => -32011}}}} =
      Client.request(client, "tools/call", %{"name" => "get_date"})

    assert_auth_event(
      TelemetryCapture.drain(ref, instance),
      instance,
      :authorize,
      :insufficient_scope
    )
  end

  @tag server: Servers.Scoped
  test "a call without the required scopes of the tool gives one refusal event", %{
    base_url: url,
    instance: instance
  } do
    ref = TelemetryCapture.attach()

    client = url |> Client.new(bearer("alice-token")) |> Client.ready!()

    {_client, {403, _headers, %{"error" => %{"code" => -32011}}}} =
      Client.request(client, "tools/call", %{
        "name" => "write_file",
        "arguments" => %{"path" => "note.txt"}
      })

    assert_auth_event(
      TelemetryCapture.drain(ref, instance),
      instance,
      :required_scopes,
      :insufficient_scope
    )
  end

  @tag server: Servers.AuthorizedIsolation
  test "a read that the callback forbids gives one refusal event", %{
    base_url: url,
    instance: instance
  } do
    ref = TelemetryCapture.attach()

    client = url |> Client.new(bearer("alice-token")) |> Client.ready!()

    {_client, {403, _headers, %{"error" => %{"code" => -32011}}}} =
      Client.request(client, "resources/read", %{"uri" => "file:///marketing.md"})

    assert_auth_event(TelemetryCapture.drain(ref, instance), instance, :authorize, :forbidden)
  end

  @tag server: Servers.AuthorizedBroken
  test "a verifier that raises gives one refusal event", %{base_url: url, instance: instance} do
    ref = TelemetryCapture.attach()

    Utils.capture_log([level: :error], fn ->
      {_client, {500, _headers, %{"error" => %{"code" => -32603}}}} =
        Client.new(url, bearer("raise-token")) |> Client.initialize()
    end)

    assert_auth_event(
      TelemetryCapture.drain(ref, instance),
      instance,
      :authenticate,
      :verifier_error
    )
  end

  @capabilities %{"elicitation" => %{"form" => %{}}}
  @answer_timeout 10_000

  @tag server: Servers.AuthorizedStreams
  test "a POST stream stops writing at the expiry of the token and the client resumes",
       %{base_url: url} do
    #
    # Two tokens of one principal: the session accepts the second one
    # when the first is gone.
    #
    token = Support.Auth.Default.register_token()
    fresh = Support.Auth.Default.register_token()
    Support.Auth.Default.expire_at(token, System.system_time(:millisecond) / 1000 + 1.0)

    client = url |> Client.new(bearer(token)) |> Client.ready!(capabilities: @capabilities)

    {client, resp1, sse1} =
      Client.stream_request(client, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"feature" => "elicit_form", "timeout" => @answer_timeout}
      })

    {:ok, elicitation, sse1} = Client.next_event(resp1, sse1)
    elicitation_message = JSON.decode!(elicitation.data)
    assert %{"method" => "elicitation/create"} = elicitation_message

    # At the expiry of the token, the stream of the request writes the
    # retry hint and ends the connection: the callback goes on.
    #
    {_last_id, sse1} = wait_for_retry(resp1, sse1)

    # The old connection ends with no result, before the client answers:
    # the response will go to the event log of the session.
    #
    {:ended, frames1, _sse} = Client.drain(resp1, sse1, 10_000)

    refute Enum.any?(frames1, fn frame ->
             frame.data != "" and String.contains?(frame.data, "\"result\"")
           end)

    # The client answers the elicitation with the second token.
    #
    answerer = %{Client.new(url, bearer(fresh)) | session_id: client.session_id}

    {_answerer, {202, _headers, nil}} =
      Client.answer(answerer, elicitation_message, %{
        "action" => "accept",
        "content" => %{"name" => "Ada"}
      })

    # A GET with the second token and Last-Event-ID gets the response of
    # the request and then the stream ends.
    #
    {resp2, sse2} =
      Client.open_get(answerer, last_event_id: elicitation.id, headers: bearer(fresh))

    {:ok, answer_event, _sse} = Client.next_event(resp2, sse2)

    assert %{"id" => 2, "result" => %{"content" => [%{"type" => "text", "text" => text}]}} =
             JSON.decode!(answer_event.data)

    assert text =~ "\"Ada\""

    {:ended, _sse} = Client.next_frame(resp2, sse2)
  end

  @tag server: Servers.AuthorizedStreams
  test "the stream of a task result stops writing at the expiry of the token and the client resumes",
       %{base_url: url} do
    token = Support.Auth.Default.register_token()
    fresh = Support.Auth.Default.register_token()
    Support.Auth.Default.expire_at(token, System.system_time(:millisecond) / 1000 + 1.0)

    client = url |> Client.new(bearer(token)) |> Client.ready!(capabilities: @capabilities)

    {_client, {200, _headers, %{"result" => %{"task" => task}}}} =
      Client.request(client, "tools/call", %{"name" => "task_slow", "task" => %{}})

    {client, resp1, sse1} =
      Client.stream_request(client, "tasks/result", %{"taskId" => task["taskId"]})

    result_id = client.next_id - 1

    # At the expiry of the token, the stream of the wait writes the
    # retry hint and ends the connection: the task goes on.
    #
    {last_id, sse1} = wait_for_retry(resp1, sse1)
    assert is_binary(last_id)

    # The old connection ends with no result, before the task finishes:
    # the outcome will go to the event log of the session.
    #
    {:ended, frames1, _sse} = Client.drain(resp1, sse1, 10_000)

    refute Enum.any?(frames1, fn frame ->
             frame.data != "" and String.contains?(frame.data, "\"result\"")
           end)

    # The test ends the task.
    #
    wait_for_runner()
    Support.Entities.Tools.TaskSlowTest.finish()

    # A GET with the second token and Last-Event-ID gets the outcome of
    # the task and then the stream ends.
    #
    answerer = %{Client.new(url, bearer(fresh)) | session_id: client.session_id}

    {resp2, sse2} =
      Client.open_get(answerer, last_event_id: last_id, headers: bearer(fresh))

    {result, _sse} = wait_for_answer(resp2, sse2, result_id)

    assert %{
             "id" => ^result_id,
             "result" => %{"content" => [%{"type" => "text", "text" => "slow done"}]}
           } = result

    {:ended, _sse} = Client.next_frame(resp2, sse2)
  end

  defp bearer(token), do: [{"authorization", "Bearer " <> token}]

  defp get_header(headers, name) do
    case Map.get(headers, name, []) do
      [value | _rest] -> value
      _other -> nil
    end
  end

  # The refusal is emitted before the answer goes out, so the drain after
  # the answer holds every event of the request: exactly one refusal.
  #
  defp assert_auth_event(events, instance, stage, reason) do
    auth = Enum.filter(events, fn {name, _, _} -> name == [:oz_mcp, :auth, :refused] end)
    assert [{_, %{count: 1}, meta}] = auth
    assert meta.instance == instance
    assert meta.stage == stage
    assert meta.reason == reason

    for {_, _, meta} <- auth do
      assert Map.keys(meta) |> Enum.sort() == [:instance, :reason, :server, :stage]
      refute Enum.any?(Map.values(meta), &(is_binary(&1) and String.contains?(&1, "alice-token")))
    end
  end

  defp any_auth_event?(events),
    do: Enum.any?(events, fn {name, _, _} -> name == [:oz_mcp, :auth, :refused] end)

  # The frames of an open stream until the `retry:` hint arrives (the
  # expiry of the principal). The function also gives the last event id
  # that the client saw, for the resume with `Last-Event-ID`.
  #
  defp wait_for_retry(resp, sse, tries \\ 10), do: wait_for_retry(resp, sse, nil, tries)

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

  # The events of a resumed stream until the answer of a request arrives.
  #
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

  # The task of the test runs until the test tells it to finish.
  #
  defp wait_for_runner do
    assert Utils.eventually(fn ->
             Support.Entities.Tools.TaskSlowTest.last_runner_pid() != nil
           end)

    :ok
  end
end
