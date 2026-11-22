defmodule OzMcp.E2E.HttpServerTest do
  use OzMcp.E2ECase, async: true

  for kind <- [:bandit, :cowboy] do
    @tag http_server: kind
    test "initialize, tools/list and a GET stream work on #{kind}", %{base_url: url} do
      client = url |> Client.new() |> Client.ready!()

      {_client, {200, _headers, %{"result" => %{"tools" => [_ | _]}}}} =
        Client.request(client, "tools/list")

      {resp, sse} = Client.open_get(client)
      assert {:ok, %{retry: 1000, data: ""}, _sse} = Client.next_frame(resp, sse)
    end
  end
end
