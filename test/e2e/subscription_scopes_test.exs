#
# The end of a subscription when a request shows a principal without the
# scopes that the resource needs, over a real connection: one session,
# two tokens of different scopes. A `POST` request and the open of a
# `GET` stream (a fresh one, or a resume) both check the subscriptions:
# the subscription whose scopes the token of the request does not cover
# goes, the update of the resource sends nothing, a token with all the
# scopes keeps its subscription and the subscription that needs no scope
# stays.
#
defmodule OzMcp.E2E.SubscriptionScopesTest do
  use OzMcp.E2ECase, async: true

  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  @moduletag server: Servers.Scoped
  @moduletag server_opts: %{resource_url: "https://mcp.example.com/mcp"}

  test "a request with a token of fewer scopes ends the subscription that needs a scope", %{
    base_url: url,
    instance: instance
  } do
    ref = TelemetryCapture.attach()

    admin = url |> Client.new(bearer("alice-admin")) |> Client.ready!()
    {resp, sse} = Client.open_get(admin, headers: bearer("alice-admin"))

    {_admin, {200, _h, %{"result" => %{}}}} =
      Client.request(admin, "resources/subscribe", %{"uri" => "file:///secret.md"})

    {_admin, {200, _h, %{"result" => %{}}}} =
      Client.request(admin, "resources/subscribe", %{"uri" => "file:///public.md"})

    # The same session, with a token of the same principal that holds the
    # read scope only: the touch of the request checks the subscriptions.
    #
    reader = %{Client.new(url, bearer("alice-token")) | session_id: admin.session_id}

    {_reader, {200, _h, %{"result" => %{}}}} = Client.request(reader, "ping")

    assert Utils.eventually(
             fn ->
               Utils.subscriptions(instance, admin.session_id) == ["file:///public.md"]
             end,
             2_000
           )

    assert Utils.session_data(instance, admin.session_id).subscription_scopes == %{}

    # The update of the scoped resource sends nothing: the next event of
    # the stream is the notification of the public resource.
    #
    :ok = OzMcp.Notify.resource_updated(instance, "file:///secret.md")
    :ok = OzMcp.Notify.resource_updated(instance, "file:///public.md")

    {:ok, event, _sse} = Client.next_event(resp, sse)

    assert %{
             "method" => "notifications/resources/updated",
             "params" => %{"uri" => "file:///public.md"}
           } = JSON.decode!(event.data)

    assert [{[:oz_mcp, :subscription, :dropped], %{count: 1}, meta}] =
             TelemetryCapture.drain(ref, instance)
             |> Enum.filter(fn {name, _, _} -> name == [:oz_mcp, :subscription, :dropped] end)

    assert meta.reason == :scope
  end

  test "the open of a GET stream with a token of fewer scopes ends the subscription", %{
    base_url: url,
    instance: instance
  } do
    ref = TelemetryCapture.attach()

    admin = url |> Client.new(bearer("alice-admin")) |> Client.ready!()

    {_admin, {200, _h, %{"result" => %{}}}} =
      Client.request(admin, "resources/subscribe", %{"uri" => "file:///secret.md"})

    {_admin, {200, _h, %{"result" => %{}}}} =
      Client.request(admin, "resources/subscribe", %{"uri" => "file:///public.md"})

    # The stream of the session, opened with a token of the same principal
    # that holds the read scope only: the open of the stream checks the
    # subscriptions.
    #
    reader = %{Client.new(url) | session_id: admin.session_id}
    {resp, sse} = Client.open_get(reader, headers: bearer("alice-token"))

    assert Utils.eventually(
             fn ->
               Utils.subscriptions(instance, admin.session_id) == ["file:///public.md"]
             end,
             2_000
           )

    # The update of the scoped resource sends nothing: the next event of
    # the stream is the notification of the public resource.
    #
    :ok = OzMcp.Notify.resource_updated(instance, "file:///secret.md")
    :ok = OzMcp.Notify.resource_updated(instance, "file:///public.md")

    {:ok, event, _sse} = Client.next_event(resp, sse)

    assert %{
             "method" => "notifications/resources/updated",
             "params" => %{"uri" => "file:///public.md"}
           } = JSON.decode!(event.data)

    assert [{[:oz_mcp, :subscription, :dropped], %{count: 1}, meta}] =
             TelemetryCapture.drain(ref, instance)
             |> Enum.filter(fn {name, _, _} -> name == [:oz_mcp, :subscription, :dropped] end)

    assert meta.reason == :scope
  end

  test "a GET stream that resumes with a token of fewer scopes ends the subscription", %{
    base_url: url,
    instance: instance
  } do
    ref = TelemetryCapture.attach()

    admin = url |> Client.new(bearer("alice-admin")) |> Client.ready!()

    {_admin, {200, _h, %{"result" => %{}}}} =
      Client.request(admin, "resources/subscribe", %{"uri" => "file:///secret.md"})

    {resp1, sse1} = Client.open_get(admin, headers: bearer("alice-admin"))
    :ok = Support.Helpers.Broadcast.notify_all(instance)
    {:ok, event, _sse1} = Client.next_event(resp1, sse1)

    # The connection of the stream is gone. The client reconnects with its
    # Last-Event-ID and a token of the same principal that holds the read
    # scope only: the open of the new stream checks the subscriptions.
    #
    Client.cancel_stream(resp1)

    reader = %{Client.new(url, bearer("alice-token")) | session_id: admin.session_id}

    {resp2, sse2} =
      Client.open_get(reader, last_event_id: event.id, headers: bearer("alice-token"))

    assert Utils.eventually(
             fn -> Utils.subscriptions(instance, admin.session_id) == [] end,
             2_000
           )

    # The update of the scoped resource sends nothing to the resumed
    # stream: the next event is the notification of the list of tools.
    #
    :ok = OzMcp.Notify.resource_updated(instance, "file:///secret.md")
    :ok = Support.Helpers.Broadcast.notify_all(instance)

    {:ok, next, _sse2} = Client.next_event(resp2, sse2)
    assert %{"method" => "notifications/tools/list_changed"} = JSON.decode!(next.data)

    assert [{[:oz_mcp, :subscription, :dropped], %{count: 1}, meta}] =
             TelemetryCapture.drain(ref, instance)
             |> Enum.filter(fn {name, _, _} -> name == [:oz_mcp, :subscription, :dropped] end)

    assert meta.reason == :scope
  end

  test "the open of a GET stream with a token of all the scopes keeps the subscription", %{
    base_url: url,
    instance: instance
  } do
    admin = url |> Client.new(bearer("alice-admin")) |> Client.ready!()

    {_admin, {200, _h, %{"result" => %{}}}} =
      Client.request(admin, "resources/subscribe", %{"uri" => "file:///secret.md"})

    {resp, sse} = Client.open_get(admin, headers: bearer("alice-admin"))

    # The token of the stream holds the scope of the subscription: the
    # subscription stays and the update arrives.
    #
    :ok = OzMcp.Notify.resource_updated(instance, "file:///secret.md")
    {:ok, event, _sse} = Client.next_event(resp, sse)

    assert %{
             "method" => "notifications/resources/updated",
             "params" => %{"uri" => "file:///secret.md"}
           } = JSON.decode!(event.data)

    assert Utils.subscriptions(instance, admin.session_id) == ["file:///secret.md"]
  end

  defp bearer(token), do: [{"authorization", "Bearer " <> token}]
end
