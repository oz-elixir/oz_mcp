defmodule OzMcp.Transport.Http.CorsTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias OzMcp.Transport.Http.Cors
  alias Support.Helpers.Utils
  alias Support.Servers

  # The instance that serves a server module in this file.
  #
  defp inst(module), do: Module.concat(module, __MODULE__)

  @origin "http://localhost:3000"
  @server Servers.Default

  # Unit tests with plain connection structs and option lists.
  #
  describe "validate_cors_origin/2" do
    test "a request with no Origin header passes with no origin" do
      assert Cors.validate_cors_origin(conn(:get, "/"), allowed_origins: [@origin]) ==
               {:ok, nil}
    end

    test "a listed origin passes" do
      conn = conn(:get, "/") |> put_req_header("origin", @origin)

      assert Cors.validate_cors_origin(conn, allowed_origins: [@origin]) == {:ok, @origin}
    end

    test "an unlisted origin is forbidden" do
      conn = conn(:get, "/") |> put_req_header("origin", "http://evil.example")

      assert Cors.validate_cors_origin(conn, allowed_origins: [@origin]) == :forbidden
    end

    test "any origin is forbidden when the list is empty" do
      conn = conn(:get, "/") |> put_req_header("origin", @origin)

      assert Cors.validate_cors_origin(conn, allowed_origins: []) == :forbidden
    end

    test "two Origin header fields are forbidden" do
      conn =
        conn(:get, "/")
        |> Map.put(:req_headers, [{"origin", @origin}, {"origin", @origin}])

      assert Cors.validate_cors_origin(conn, allowed_origins: [@origin]) == :forbidden
    end

    test "the origin is compared as a string: no wildcard" do
      conn = conn(:get, "/") |> put_req_header("origin", "https://app.example.com")

      assert Cors.validate_cors_origin(conn, allowed_origins: ["*"]) == :forbidden
    end
  end

  describe "allow_headers/0" do
    test "the wildcard covers the simple headers, the authorization name is listed" do
      assert Cors.allow_headers() == "*, authorization"
    end
  end

  describe "allowed_origins/1" do
    test "the plug option wins" do
      assert Cors.allowed_origins(allowed_origins: [@origin], instance: self()) == [@origin]
    end

    test "without the plug option, the list of the instance config" do
      Utils.start_instance(@server, name: inst(@server), allowed_origins: [@origin])

      opts = OzMcp.Router.init(server: inst(@server))

      assert Cors.allowed_origins(opts) == [@origin]
    end

    test "an instance that does not run allows no origin" do
      assert Cors.allowed_origins(instance: :no_such_instance) == []
    end
  end

  describe "put_cors_headers/1" do
    test "a request with an allowed origin gets the CORS headers" do
      conn = put_private(conn(:get, "/"), :cors_origin, @origin)

      headers = conn |> Cors.put_cors_headers() |> resp_headers_map()

      assert headers["access-control-allow-origin"] == @origin
      assert headers["vary"] == "Origin"

      assert headers["access-control-expose-headers"] ==
               "mcp-session-id, mcp-protocol-version, www-authenticate"
    end

    test "a request with no origin gets none of the headers" do
      headers = conn(:get, "/") |> Cors.put_cors_headers() |> Map.get(:resp_headers)

      refute {"access-control-allow-origin", @origin} in headers
      refute {"vary", "Origin"} in headers
      refute Enum.any?(headers, fn {name, _value} -> name == "access-control-expose-headers" end)
    end
  end

  # Router tests: the preflight of the endpoint.
  #
  describe "the preflight" do
    setup do
      Utils.start_instances([@server], __MODULE__, allowed_origins: [@origin])
      :ok
    end

    test "answers 204 with the CORS headers and no content-type" do
      conn =
        conn(:options, "/")
        |> put_req_header("origin", @origin)
        |> call_router()

      assert conn.status == 204
      assert conn.resp_body == ""

      headers = Enum.into(conn.resp_headers, %{})
      assert headers["access-control-allow-origin"] == @origin
      assert headers["vary"] == "Origin"
      assert headers["access-control-allow-methods"] == "GET, POST, DELETE, OPTIONS"
      assert headers["access-control-allow-headers"] == "*, authorization"
      refute Map.has_key?(headers, "content-type")
    end

    test "lets the browser send the Authorization header" do
      conn =
        conn(:options, "/")
        |> put_req_header("origin", @origin)
        |> call_router()

      headers = Enum.into(conn.resp_headers, %{})
      assert headers["access-control-allow-headers"] =~ "authorization"
    end

    test "works for any path" do
      conn =
        conn(:options, "/any/path")
        |> put_req_header("origin", @origin)
        |> call_router()

      assert conn.status == 204
    end

    test "an unlisted origin gets 403 with an empty body and no CORS headers" do
      conn =
        conn(:options, "/")
        |> put_req_header("origin", "http://evil.example")
        |> call_router()

      assert conn.status == 403
      assert conn.resp_body == ""

      headers = Enum.into(conn.resp_headers, %{})
      refute Map.has_key?(headers, "access-control-allow-origin")
    end
  end

  describe "the origin check of the router" do
    setup do
      Utils.start_instances([@server], __MODULE__, allowed_origins: [@origin])
      :ok
    end

    test "a listed origin is echoed on every answer" do
      conn =
        post_initialize()
        |> put_req_header("origin", @origin)
        |> call_router()

      assert conn.status == 200

      headers = Enum.into(conn.resp_headers, %{})
      assert headers["access-control-allow-origin"] == @origin
      assert headers["vary"] == "Origin"
    end

    test "an unlisted origin gets 403 with an empty body and no content-type" do
      conn =
        post_initialize()
        |> put_req_header("origin", "http://evil.example")
        |> call_router()

      assert conn.status == 403
      assert conn.resp_body == ""

      headers = Enum.into(conn.resp_headers, %{})
      refute Map.has_key?(headers, "access-control-allow-origin")
      refute Map.has_key?(headers, "content-type")
    end

    test "a request with no origin gets no CORS headers" do
      conn = post_initialize() |> call_router()

      assert conn.status == 200

      headers = Enum.into(conn.resp_headers, %{})
      refute Map.has_key?(headers, "access-control-allow-origin")
      refute Map.has_key?(headers, "vary")
    end
  end

  defp resp_headers_map(conn), do: Map.new(conn.resp_headers)

  defp inst_with_router, do: OzMcp.Router.init(server: inst(@server), allowed_origins: [@origin])

  defp call_router(conn), do: OzMcp.Router.call(conn, inst_with_router())

  defp post_initialize do
    body =
      JSON.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-11-25",
          capabilities: %{},
          clientInfo: %{name: "cors-test", version: "1.0"}
        }
      })

    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
  end
end
