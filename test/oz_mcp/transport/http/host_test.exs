defmodule OzMcp.Transport.Http.HostTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias OzMcp.Transport.Http.Host
  alias Support.Helpers.Utils
  alias Support.Servers

  # The instance that serves a server module in this file.
  #
  defp inst(module), do: Module.concat(module, __MODULE__)

  @server Servers.Default

  # Unit tests of allowed?/2 with plain connection structs.
  #
  describe "allowed?/2" do
    test ":any accepts every host" do
      conn = %Plug.Conn{host: "anything.example.com"}

      assert Host.allowed?(conn, :any)
      assert Host.allowed?(%Plug.Conn{host: nil}, :any)
    end

    test "a list with the host accepts the request" do
      assert Host.allowed?(%Plug.Conn{host: "localhost"}, ["localhost"])
    end

    test "a list without the host refuses the request" do
      refute Host.allowed?(%Plug.Conn{host: "evil.example.com"}, ["localhost", "[::1]"])
    end

    test "the compare of the request host ignores its case" do
      assert Host.allowed?(%Plug.Conn{host: "LOCALHOST"}, ["localhost"])
      assert Host.allowed?(%Plug.Conn{host: "Local.Example.COM"}, ["local.example.com"])
    end

    test "the names of the list compare as they are" do
      #
      # The boot lower-cases the list; the module compares the host of the
      # request against the names it gets.
      #
      refute Host.allowed?(%Plug.Conn{host: "localhost"}, ["LOCALHOST"])
    end

    test "an IPv6 host keeps its brackets" do
      assert Host.allowed?(%Plug.Conn{host: "[::1]"}, ["localhost", "[::1]"])
      refute Host.allowed?(%Plug.Conn{host: "::1"}, ["localhost", "[::1]"])
    end

    test "the host of the request holds no port" do
      conn = conn(:get, "http://localhost:4000/")

      assert conn.host == "localhost"
      assert Host.allowed?(conn, ["localhost"])
      refute Host.allowed?(conn, ["localhost:4000"])
    end
  end

  # Router tests: the check runs before the origin check and a refused
  # host gets `403` with an empty body.
  #
  describe "the router" do
    setup do
      Utils.start_instances([{@server, %{allowed_hosts: ["localhost", "[::1]"]}}], __MODULE__)

      :ok
    end

    test "a request with an allowed host passes" do
      conn = initialize_request("http://localhost:4000/") |> call_router()

      assert conn.status == 200
    end

    test "a request with a host that the list does not name gets 403 with an empty body" do
      conn = initialize_request("http://evil.example.com/") |> call_router()

      assert conn.status == 403
      assert conn.resp_body == ""
    end

    test "the compare of the host ignores its case" do
      conn = initialize_request("http://LOCALHost:4000/") |> call_router()

      assert conn.status == 200
    end

    test "an IPv6 host keeps its brackets" do
      #
      # The test adapter reads the host from the URI, which drops the
      # brackets. The HTTP server keeps them: the check compares the host
      # that the adapter gives, so the test sets it on the connection.
      #
      conn =
        initialize_request("http://localhost:4000/")
        |> Map.put(:host, "[::1]")
        |> call_router()

      assert conn.status == 200

      conn =
        initialize_request("http://localhost:4000/")
        |> Map.put(:host, "2001:db8::1")
        |> call_router()

      assert conn.status == 403
    end

    test "the host check runs before the origin check" do
      #
      # The origin would pass (no `Origin` header), the host refuses.
      #
      conn = initialize_request("http://evil.example.com/") |> call_router()

      assert conn.status == 403
      assert conn.resp_body == ""
    end

    test "the preflight obeys the host list" do
      conn = conn(:options, "http://localhost:4000/") |> call_router()

      assert conn.status == 204

      conn = conn(:options, "http://evil.example.com/") |> call_router()

      assert conn.status == 403
      assert conn.resp_body == ""
    end

    test "the default :any accepts every host" do
      Utils.start_instances([@server], OtherTag)

      conn =
        initialize_request("http://anything.example.com/")
        |> OzMcp.Router.call(OzMcp.Router.init(server: inst_with(OtherTag)))

      assert conn.status == 200
    end
  end

  # An instance that does not run gets 503 for every method and path,
  # before the host check and the origin check.
  #
  describe "a stopped instance" do
    test "gets 503 for POST, GET, DELETE and OPTIONS" do
      for method <- [:post, :get, :delete, :options] do
        conn =
          conn(method, "/")
          |> OzMcp.Router.call(instance: :no_such_instance)

        assert conn.status == 503, "expected #{method} to be refused with 503"
      end
    end

    test "its 503 names no CORS origin, also when the request carries an Origin header" do
      conn =
        conn(:post, "/")
        |> put_req_header("origin", "https://app.example.com")
        |> OzMcp.Router.call(instance: :no_such_instance)

      assert conn.status == 503
      refute Map.has_key?(Enum.into(conn.resp_headers, %{}), "access-control-allow-origin")
    end
  end

  defp inst_with(tag), do: Module.concat(@server, tag)

  defp call_router(conn) do
    OzMcp.Router.call(conn, OzMcp.Router.init(server: inst(@server)))
  end

  defp initialize_request(url) do
    body =
      JSON.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-11-25",
          capabilities: %{},
          clientInfo: %{name: "host-test", version: "1.0"}
        }
      })

    conn(:post, url, body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
  end
end
