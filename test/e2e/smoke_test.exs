defmodule OzMcp.E2E.SmokeTest do
  use OzMcp.E2ECase, async: true

  test "initialize, initialized, tools/list and DELETE", %{base_url: url} do
    client = Client.new(url)

    {client, {200, _h, %{"result" => %{"protocolVersion" => "2025-11-25"}}}} =
      Client.initialize(client)

    {client, {202, _h, nil}} = Client.notify(client, "notifications/initialized")

    {client, {200, _h, %{"result" => %{"tools" => [_ | _]}}}} =
      Client.request(client, "tools/list")

    assert {_client, {200, _h, nil}} = Client.delete(client)
  end
end
