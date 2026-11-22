defmodule OzMcp.E2E.SdkServerTest do
  use OzMcp.E2ECase, async: true

  @tag server: OzMcp.E2E.SdkServer
  test "initialize, tools/list and tools/call", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {client, {200, _headers, %{"result" => %{"tools" => tools}}}} =
      Client.request(client, "tools/list")

    assert tools |> Enum.map(& &1["name"]) |> Enum.sort() ==
             ["sdk_echo", "sdk_elicit", "sdk_notify", "sdk_task"]

    {_client, {200, _headers, %{"result" => %{"content" => content}}}} =
      Client.request(client, "tools/call", %{
        "name" => "sdk_echo",
        "arguments" => %{"text" => "hi"}
      })

    assert content == [%{"type" => "text", "text" => "hi"}]
  end
end
