defmodule OzMcp.RouterOriginsTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn
  alias Support.Helpers.Utils
  alias Support.Servers

  # The instance that serves a server module in this file.
  #
  defp inst(module), do: Module.concat(module, __MODULE__)

  @runtime_origin "https://app.example.com"
  @plug_origin "http://localhost:3000"
  @evil_origin "https://evil.example.com"

  setup do
    Utils.start_instances([Servers.Default], __MODULE__, allowed_origins: [@runtime_origin])

    :ok
  end

  test "the router uses the list of the runtime when the plug has no option" do
    opts = OzMcp.Router.init(server: inst(Servers.Default))

    conn =
      initialize_request()
      |> put_req_header("origin", @runtime_origin)
      |> OzMcp.Router.call(opts)

    assert conn.status == 200

    conn =
      initialize_request()
      |> put_req_header("origin", @evil_origin)
      |> OzMcp.Router.call(opts)

    assert conn.status == 403
    assert conn.resp_body == ""
  end

  test "the plug option wins over the list of the runtime" do
    opts =
      OzMcp.Router.init(server: inst(Servers.Default), allowed_origins: [@plug_origin])

    conn =
      initialize_request()
      |> put_req_header("origin", @plug_origin)
      |> OzMcp.Router.call(opts)

    assert conn.status == 200

    conn =
      initialize_request()
      |> put_req_header("origin", @runtime_origin)
      |> OzMcp.Router.call(opts)

    assert conn.status == 403
  end

  test "the preflight obeys the list of the runtime when the plug has no option" do
    opts = OzMcp.Router.init(server: inst(Servers.Default))

    conn =
      conn(:options, "/")
      |> put_req_header("origin", @runtime_origin)
      |> OzMcp.Router.call(opts)

    assert conn.status == 204

    headers = Enum.into(conn.resp_headers, %{})
    assert headers["access-control-allow-origin"] == @runtime_origin

    conn =
      conn(:options, "/")
      |> put_req_header("origin", @evil_origin)
      |> OzMcp.Router.call(opts)

    assert conn.status == 403
  end

  test "the preflight obeys the plug option" do
    opts =
      OzMcp.Router.init(server: inst(Servers.Default), allowed_origins: [@plug_origin])

    conn =
      conn(:options, "/")
      |> put_req_header("origin", @runtime_origin)
      |> OzMcp.Router.call(opts)

    assert conn.status == 403

    conn =
      conn(:options, "/")
      |> put_req_header("origin", @plug_origin)
      |> OzMcp.Router.call(opts)

    assert conn.status == 204
  end

  test "a request with no Origin header passes" do
    opts = OzMcp.Router.init(server: inst(Servers.Default))

    conn = initialize_request() |> OzMcp.Router.call(opts)

    assert conn.status == 200

    headers = Enum.into(conn.resp_headers, %{})
    refute Map.has_key?(headers, "access-control-allow-origin")
  end

  defp initialize_request do
    body =
      JSON.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-11-25",
          capabilities: %{},
          clientInfo: %{name: "origins-test", version: "1.0"}
        }
      })

    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
  end
end
