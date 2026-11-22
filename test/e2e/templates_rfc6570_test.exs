#
# The resource templates with the operators of RFC 6570 over a real
# connection: a simple variable takes one segment and never a decoded
# `/`, a reserved string crosses the segments and decodes, the query
# values are optional and come in any order, a bad triplet gives no
# match, the list shows the template strings and a completion accepts
# a template string as its ref uri.
#
defmodule OzMcp.E2E.TemplatesRfc6570Test do
  use OzMcp.E2ECase, async: true

  alias OzMcp.E2E.Conformance
  alias Support.Servers

  @moduletag server: Servers.Rfc6570

  # The read callback of the template reports to the probe of the
  # instance: each test registers itself under a name of its own.
  #
  setup %{instance: instance} do
    Process.register(self(), Module.concat(instance, "TemplateProbe"))
    :ok
  end

  test "a simple variable takes one segment and decodes", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, _h, %{"result" => result}}} =
      Client.request(client, "resources/read", %{"uri" => "app://users/42"})

    Conformance.assert_result!("resources/read", result)
    assert [%{"text" => text}] = result["contents"]
    assert JSON.decode!(text) == %{"id" => "42"}
    assert_received {:read_called, %{"id" => "42"}}
  end

  test "a simple variable does not cross '/' and the read callback is not called", %{
    base_url: url
  } do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, _h, body}} =
      Client.request(client, "resources/read", %{"uri" => "app://users/42/delete"})

    Conformance.assert_error_response!(body)
    assert %{"error" => %{"code" => -32002}} = body

    refute_received {:read_called, _}
  end

  test "a decoded '/' in a simple value gives no match and the read callback is not called", %{
    base_url: url
  } do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, _h, body}} =
      Client.request(client, "resources/read", %{"uri" => "app://users/42%2Fdelete"})

    Conformance.assert_error_response!(body)
    assert %{"error" => %{"code" => -32002}} = body

    refute_received {:read_called, _}
  end

  test "a reserved string crosses '/'", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, _h, %{"result" => result}}} =
      Client.request(client, "resources/read", %{"uri" => "file:///a/b/c.md"})

    Conformance.assert_result!("resources/read", result)
    assert [%{"text" => text}] = result["contents"]
    assert JSON.decode!(text) == %{"path" => "a/b/c.md"}
  end

  test "a reserved string decodes a percent triplet", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, _h, %{"result" => result}}} =
      Client.request(client, "resources/read", %{"uri" => "file:///a%20b.md"})

    Conformance.assert_result!("resources/read", result)
    assert [%{"text" => text}] = result["contents"]
    assert JSON.decode!(text) == %{"path" => "a b.md"}
  end

  test "query values are optional, come in any order and decode", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, _h, %{"result" => result}}} =
      Client.request(client, "resources/read", %{"uri" => "app://search?q=a%26b&page=2"})

    Conformance.assert_result!("resources/read", result)
    assert [%{"text" => text}] = result["contents"]
    assert JSON.decode!(text) == %{"q" => "a&b", "page" => "2"}

    {_client, {200, _h, %{"result" => result}}} =
      Client.request(client, "resources/read", %{"uri" => "app://search"})

    Conformance.assert_result!("resources/read", result)
    assert [%{"text" => text}] = result["contents"]
    assert JSON.decode!(text) == %{}
  end

  test "a bad percent triplet gives no match", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, _h, body}} =
      Client.request(client, "resources/read", %{"uri" => "file:///%zz"})

    Conformance.assert_error_response!(body)
    assert %{"error" => %{"code" => -32002}} = body
  end

  test "resources/templates/list shows the template strings in the declared order", %{
    base_url: url
  } do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, _h, %{"result" => result}}} =
      Client.request(client, "resources/templates/list")

    Conformance.assert_result!("resources/templates/list", result)

    assert Enum.map(result["resourceTemplates"], & &1["uriTemplate"]) == [
             "app://users/{id}",
             "file:///{+path}",
             "app://search{?q,page}",
             "app://api{/ver,id}"
           ]
  end

  test "completion/complete accepts a template string as the ref uri", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, _h, %{"result" => result}}} =
      Client.request(client, "completion/complete", %{
        "ref" => %{"type" => "ref/resource", "uri" => "file:///{+path}"},
        "argument" => %{"name" => "path", "value" => "in"}
      })

    Conformance.assert_result!("completion/complete", result)
    assert %{"values" => ["intro.md", "index.md"]} = result["completion"]
  end
end
