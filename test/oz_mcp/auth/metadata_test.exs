defmodule OzMcp.Auth.MetadataTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn
  import Support.Factories.Server

  alias OzMcp.Auth.Metadata
  alias Support.Helpers.Utils
  alias Support.Servers

  require Support.Factories.Tool

  # The instance that serves a server module in this file.
  #
  defp inst(module), do: Module.concat(module, __MODULE__)

  @resource_url "https://mcp.example.com/mcp"
  @root_resource_url "https://root.example.com"

  setup do
    Utils.start_instances(
      [
        {Servers.Authorized, %{resource_url: @resource_url}},
        {Servers.AuthorizedLocalhost, %{resource_url: @root_resource_url}},
        {Servers.Default, %{}}
      ],
      __MODULE__,
      allowed_origins: []
    )

    :ok
  end

  describe "url/1" do
    test "inserts the well-known path before the path of the resource URL" do
      assert Metadata.url("https://mcp.example.com/mcp") ==
               "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"
    end

    test "uses the well-known path alone when the resource URL has no path" do
      assert Metadata.url("https://mcp.example.com") ==
               "https://mcp.example.com/.well-known/oauth-protected-resource"
    end

    test "keeps the port of the resource URL" do
      assert Metadata.url("https://mcp.example.com:8443/mcp") ==
               "https://mcp.example.com:8443/.well-known/oauth-protected-resource/mcp"
    end

    test "keeps a path with two segments" do
      assert Metadata.url("https://mcp.example.com/api/mcp") ==
               "https://mcp.example.com/.well-known/oauth-protected-resource/api/mcp"
    end

    test "returns nil without a resource URL" do
      assert Metadata.url(nil) == nil
    end
  end

  describe "build/2" do
    test "sends every declared field of a full authorization block" do
      auth = OzMcp.Auth.Gate.config(inst(Servers.Authorized))

      assert Metadata.build(auth, @resource_url) == %{
               "resource" => @resource_url,
               "authorization_servers" => ["https://auth.example.com"],
               "scopes_supported" => ["files:read", "files:write"],
               "bearer_methods_supported" => ["header"],
               "resource_name" => "Test MCP server",
               "resource_documentation" => "https://docs.example.com/mcp"
             }
    end

    test "drops the fields that a minimal block does not declare" do
      auth = OzMcp.Auth.Gate.config(inst(Servers.AuthorizedLocalhost))

      document = Metadata.build(auth, @root_resource_url)

      assert document == %{
               "resource" => @root_resource_url,
               "authorization_servers" => [
                 "http://localhost:8080",
                 "http://127.0.0.1",
                 "http://[::1]"
               ],
               "bearer_methods_supported" => ["header"]
             }

      refute Map.has_key?(document, "scopes_supported")
      refute Map.has_key?(document, "resource_name")
      refute Map.has_key?(document, "resource_documentation")
    end
  end

  describe "GET" do
    test "answers the document for the segments of the resource URL path" do
      conn =
        conn(:get, "/mcp")
        |> call_plug(inst(Servers.Authorized))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]

      assert get_resp_header(conn, "access-control-allow-headers") ==
               [OzMcp.Transport.Http.Cors.allow_headers()]

      assert :json.decode(conn.resp_body) == %{
               "resource" => @resource_url,
               "authorization_servers" => ["https://auth.example.com"],
               "scopes_supported" => ["files:read", "files:write"],
               "bearer_methods_supported" => ["header"],
               "resource_name" => "Test MCP server",
               "resource_documentation" => "https://docs.example.com/mcp"
             }
    end

    test "answers the document at the root when the resource URL has no path" do
      conn =
        conn(:get, "/")
        |> call_plug(inst(Servers.AuthorizedLocalhost))

      assert conn.status == 200

      document = :json.decode(conn.resp_body)

      assert document["resource"] == @root_resource_url

      assert document["authorization_servers"] == [
               "http://localhost:8080",
               "http://127.0.0.1",
               "http://[::1]"
             ]

      refute conn.resp_body =~ "null"
    end

    test "answers the document with the lower-case resource of an upper-case resource_url" do
      Utils.stop_instances()

      Utils.start_instances(
        [{Servers.Authorized, %{resource_url: "HTTPS://MCP.Example.Com/Mcp"}}],
        __MODULE__,
        allowed_origins: []
      )

      conn =
        conn(:get, "/Mcp")
        |> call_plug(inst(Servers.Authorized))

      assert conn.status == 200
      assert :json.decode(conn.resp_body)["resource"] == "https://mcp.example.com/Mcp"
    end

    test "the resource of a root-path resource_url holds no trailing slash" do
      Utils.stop_instances()

      Utils.start_instances(
        [{Servers.Authorized, %{resource_url: "HTTPS://MCP.Example.Com/"}}],
        __MODULE__,
        allowed_origins: []
      )

      conn =
        conn(:get, "/")
        |> call_plug(inst(Servers.Authorized))

      assert conn.status == 200
      assert :json.decode(conn.resp_body)["resource"] == "https://mcp.example.com"
    end

    test "the document holds no null value" do
      conn =
        conn(:get, "/mcp")
        |> call_plug(inst(Servers.Authorized))

      document = :json.decode(conn.resp_body)

      refute Enum.any?(document, fn {_key, value} -> is_nil(value) end)
      refute Enum.any?(document["scopes_supported"], &is_nil/1)
      refute conn.resp_body =~ "null"
    end

    test "answers 404 for any other path" do
      for path <- ["/", "/other", "/mcp/extra"] do
        conn =
          conn(:get, path)
          |> call_plug(inst(Servers.Authorized))

        assert conn.status == 404
      end
    end

    test "answers 404 for a server with no authorization block" do
      conn =
        conn(:get, "/mcp")
        |> call_plug(inst(Servers.Default))

      assert conn.status == 404
      assert conn.resp_body == ""
    end

    test "answers 503 for an instance that does not run" do
      conn =
        conn(:get, "/mcp")
        |> call_plug(:no_such_instance)

      assert conn.status == 503
      assert conn.resp_body == ""
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]

      assert get_resp_header(conn, "access-control-allow-headers") ==
               [OzMcp.Transport.Http.Cors.allow_headers()]
    end

    @tag :capture_log
    test "answers 500 with an empty body when the document cannot be encoded" do
      Utils.stop_instances()

      server =
        module "MetadataBadUtf8" do
          authorization do
            verifier(Support.Auth.Default)
            authorization_servers(["https://auth.example.com"])
            resource_name(<<0xFF>>)
          end
        end
        |> compile()

      Utils.start_instances([{server, %{resource_url: @resource_url}}], __MODULE__,
        allowed_origins: []
      )

      for method <- [:get, :head] do
        conn =
          conn(method, "/mcp")
          |> call_plug(inst(server))

        assert conn.status == 500
        assert conn.resp_body == ""
        assert get_resp_header(conn, "cache-control") == []
        assert get_resp_header(conn, "content-type") == []
        assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      end
    end
  end

  describe "other methods" do
    test "OPTIONS: 204 with the wildcard CORS headers" do
      conn =
        conn(:options, "/mcp")
        |> call_plug(inst(Servers.Authorized))

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["GET, HEAD, OPTIONS"]

      assert get_resp_header(conn, "access-control-allow-headers") ==
               [OzMcp.Transport.Http.Cors.allow_headers()]
    end

    test "HEAD: the document headers with no body" do
      conn =
        conn(:head, "/mcp")
        |> call_plug(inst(Servers.Authorized))

      assert conn.status == 200
      assert conn.resp_body == ""
      assert get_resp_header(conn, "content-type") == ["application/json"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
    end

    test "POST: 405 with the allow header" do
      conn =
        conn(:post, "/mcp")
        |> call_plug(inst(Servers.Authorized))

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["GET, HEAD, OPTIONS"]
    end
  end

  describe "derived scopes_supported" do
    test "the document names the scopes of the DSL when the server sets none" do
      Utils.stop_instances()

      server =
        module "MetadataDerived" do
          tools do
            tool Support.Entities.Tools.ScopedTest
          end

          resources do
            resource Support.Entities.Resources.ScopedTest
          end

          authorization do
            verifier(Support.Auth.Default)
            authorization_servers(["https://auth.example.com"])
          end
        end
        |> compile()

      Utils.start_instances([{server, %{resource_url: @resource_url}}], __MODULE__,
        allowed_origins: []
      )

      conn =
        conn(:get, "/mcp")
        |> call_plug(inst(server))

      assert conn.status == 200

      assert :json.decode(conn.resp_body) == %{
               "resource" => @resource_url,
               "authorization_servers" => ["https://auth.example.com"],
               "scopes_supported" => ["admin", "files:write"],
               "bearer_methods_supported" => ["header"]
             }
    end

    test "the document names the scopes of a map module with no constant" do
      Utils.stop_instances()

      server = map_scoped_authorized_server(["tools:write"])

      Utils.start_instances([{server, %{resource_url: @resource_url}}], __MODULE__,
        allowed_origins: []
      )

      conn =
        conn(:get, "/mcp")
        |> call_plug(inst(server))

      assert conn.status == 200

      assert :json.decode(conn.resp_body)["scopes_supported"] == ["tools:write"]
    end

    test "the document of a server whose modules need no scope has no key" do
      conn =
        conn(:get, "/")
        |> call_plug(inst(Servers.AuthorizedLocalhost))

      assert conn.status == 200
      refute Map.has_key?(:json.decode(conn.resp_body), "scopes_supported")
    end
  end

  describe "round trip with the authentication challenge" do
    test "the resource_metadata URL of the challenge is where this plug answers" do
      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> call_router()

      assert conn.status == 401

      [challenge] = get_resp_header(conn, "www-authenticate")

      [metadata_url] =
        Regex.run(~r/resource_metadata="([^"]+)"/, challenge, capture: :all_but_first)

      assert metadata_url == Metadata.url(@resource_url)

      # The host forwards the well-known prefix away: the plug receives
      # the segments of the resource URL path only.
      #
      segments =
        metadata_url
        |> URI.parse()
        |> Map.fetch!(:path)
        |> String.split("/", trim: true)
        |> Enum.drop(2)

      document =
        conn(:get, "/" <> Enum.join(segments, "/"))
        |> call_plug(inst(Servers.Authorized))

      assert document.status == 200
      assert :json.decode(document.resp_body)["resource"] == @resource_url
    end
  end

  # A protected server whose tool module has `dsl?: false` and returns
  # a map with the given scopes. The module defines no constant.
  #
  defp map_scoped_authorized_server(scopes) do
    code =
      quote do
        def list do
          [
            %{
              "name" => "scoped_map",
              "description" => "A map tool with scopes",
              "inputSchema" => %{"type" => "object"},
              "required_scopes" => unquote(scopes)
            }
          ]
        end

        def call(_ctx, _params), do: {:ok, %{"content" => []}}
      end

    tool_mod =
      Support.Factories.Tool.module("MetadataMapScopedTool", _dsl_: false, _code_: code)
      |> Support.Factories.Tool.compile()

    exprs = [
      Support.Factories.Server.__tools__([], [Support.Factories.Server.tool(tool_mod)]),
      Support.Factories.Server.__authorization__([], [
        Support.Factories.Server.verifier(Support.Auth.Default),
        Support.Factories.Server.authorization_servers(["https://auth.example.com"])
      ])
    ]

    "MetadataMapScopes"
    |> Support.Factories.Server.__module__([_tools_: :_none_], exprs)
    |> Support.Factories.Server.compile()
  end

  defp call_plug(conn, server) do
    Metadata.call(conn, Metadata.init(server: server))
  end

  defp call_router(conn) do
    OzMcp.Router.call(
      conn,
      OzMcp.Router.init(server: inst(Servers.Authorized), allowed_origins: [])
    )
  end
end
