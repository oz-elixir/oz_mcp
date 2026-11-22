defmodule OzMcp.Testing.AdapterTest do
  use ExUnit.Case, async: true

  alias OzMcp.Testing.Adapter

  test "sends the head and each chunk to the process in order" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Adapter.wrap(self(), :post)
      |> stream()

    assert_receive {:post, :head, 200, _headers}
    assert_receive {:post, :chunk, "one"}
    assert_receive {:post, :chunk, "two"}
    assert conn.resp_body == "onetwo"
  end

  test "sends no message for a response that is not streamed" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Adapter.wrap(self(), :post)
      |> Plug.Conn.send_resp(200, "hello")

    assert conn.resp_body == "hello"
    refute_received {:post, _, _, _}
    refute_received {:post, _, _}
  end

  defp stream(conn) do
    conn = Plug.Conn.send_chunked(conn, 200)
    {:ok, conn} = Plug.Conn.chunk(conn, "one")
    {:ok, conn} = Plug.Conn.chunk(conn, "two")
    conn
  end
end
