#
# The unit tests of the `DELETE` route: the end of a session. The route
# runs here on the `Plug` test connection, without the plugs of the
# router; the full plug (the host, the CORS origin, the gate) is under
# test in `OzMcp.RouterTest`.
#
defmodule OzMcp.Transport.Http.DeleteTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias OzMcp.Transport.Http.Delete
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.Default

  # The instance that serves the server module of this file.
  #
  defp inst, do: Module.concat(@server, __MODULE__)

  setup do
    Utils.start_instance(@server, name: inst())
    %{session_id: Utils.create_session(inst(), initialized: true)}
  end

  test "the session ends: 200 with no body and no content-type", %{
    session_id: session_id
  } do
    conn = delete_call(session_id)

    assert conn.status == 200
    assert conn.resp_body == ""
    refute Map.has_key?(Enum.into(conn.resp_headers, %{}), "content-type")

    assert SessionProbe.initialized?(inst(), session_id) == {:error, :no_session}
  end

  test "a session that is already gone answers 404" do
    conn = delete_call("no-such-session")

    assert conn.status == 404
    assert decoded(conn) == json_error(-32001, "invalid session")
  end

  test "an unsupported protocol version in the header answers 400", %{
    session_id: session_id
  } do
    conn =
      conn(:delete, "/")
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", "2025-06-18")
      |> put_private(:instance, inst())
      |> Delete.call()

    assert conn.status == 400
    assert decoded(conn) == json_error(-32600, "unsupported MCP protocol version")
  end

  test "an instance that cannot answer gives 503" do
    conn = delete_call("no-such-session", instance: Module.concat(@server, "Stopped"))

    assert conn.status == 503
    assert decoded(conn) == json_error(-32603, "server unavailable")
  end

  defp delete_call(session_id, opts \\ []) do
    instance = Keyword.get(opts, :instance, inst())

    conn(:delete, "/")
    |> put_req_header("mcp-session-id", session_id)
    |> put_private(:instance, instance)
    |> Delete.call()
  end

  defp decoded(conn), do: :json.decode(conn.resp_body)

  defp json_error(code, message),
    do: %{"jsonrpc" => "2.0", "error" => %{"code" => code, "message" => message}}
end
