defmodule OzMcp.Auth.Metadata do
  @moduledoc """
  Protected Resource Metadata (RFC 9728) of a protected MCP server.

  The metadata document tells the client where the authorization servers
  of this MCP server are. A client that receives a `401` challenge reads
  the `resource_metadata` URL of the `WWW-Authenticate` header, fetches
  the document there and learns which authorization server can issue a
  token for this MCP server. Its well-known URL is built from the
  canonical URL of the MCP endpoint, see `url/1`.

  The host application mounts the plug outside the MCP endpoint, because
  the well-known URL sits at the root of the host:

      forward "/.well-known/oauth-protected-resource",
        to: OzMcp.Auth.Metadata,
        init_opts: [instance: MyApp.McpServer]

  The forward prefix must be the well-known path: for a request to
  `/.well-known/oauth-protected-resource/mcp` the plug receives the
  segments of the `:resource_url` path (`["mcp"]`). The plug answers
  `200` only for those segments, `404` for any other path and for a
  server with no authorization and `503` when the instance does not
  run. The document is public: no token is checked and the CORS
  headers are a wildcard.

  Configure `:resource_url` with the public URL of the MCP endpoint and
  serve it behind TLS: the clients must be able to fetch this document
  and the endpoint at that URL.

  The `scopes_supported` field of the document is the value that the
  server sets in the `authorization` block. When the server does not
  set it, it is the sorted union of the `required_scopes` of the DSL
  modules of the server and the field is omitted when that union is
  empty.
  """

  @behaviour Plug

  import Plug.Conn

  alias OzMcp.Auth.{Gate, Scopes}
  alias OzMcp.Transport.Http.Cors
  alias OzMcp.Wire

  require Logger

  @well_known "/.well-known/oauth-protected-resource"

  @impl true
  def init(opts), do: Keyword.get(opts, :instance) || Keyword.fetch!(opts, :server)

  # A CORS preflight carries no credentials and the document is public:
  # the preflight passes.
  #
  @impl true
  def call(%Plug.Conn{method: "OPTIONS"} = conn, _instance) do
    conn
    |> cors()
    |> send_resp(204, "")
  end

  def call(%Plug.Conn{method: method} = conn, instance) when method in ["GET", "HEAD"] do
    case Gate.fetch_config(instance) do
      :not_running ->
        conn |> cors() |> send_resp(503, "")

      {:ok, nil} ->
        conn |> cors() |> send_resp(404, "")

      {:ok, auth} ->
        document(conn, method, instance, auth)
    end
  end

  def call(conn, _instance) do
    conn
    |> put_resp_header("allow", "GET, HEAD, OPTIONS")
    |> send_resp(405, "")
  end

  defp document(conn, method, instance, auth) do
    with {:ok, opts} <- OzMcp.Instance.fetch_opts(instance),
         true <- conn.path_info == path_info(opts.resource_url) do
      #
      # The document names the scopes of the DSL when the server sets no
      # scopes_supported of its own.
      #
      auth =
        Map.put(
          auth,
          :scopes_supported,
          Scopes.supported(OzMcp.Instance.server_module(instance), auth)
        )

      case Wire.encode(build(auth, opts.resource_url)) do
        {:ok, data} ->
          conn
          |> cors()
          |> put_resp_header("cache-control", "public, max-age=300")
          |> put_resp_header("content-type", "application/json")
          |> send_resp(200, body(method, data))

        {:error, path, _reason} ->
          Logger.error("the metadata document is not JSON-encodable at #{Wire.format_path(path)}")

          conn
          |> cors()
          |> delete_resp_header("cache-control")
          |> send_resp(500, "")
      end
    else
      _ -> conn |> cors() |> send_resp(404, "")
    end
  end

  @doc """
  The RFC 9728 document of the server. Keys with a `nil` value are not
  sent.
  """
  @spec build(map(), String.t()) :: map()
  def build(auth, resource_url) do
    %{
      "resource" => resource_url,
      "authorization_servers" => auth.authorization_servers,
      "scopes_supported" => auth.scopes_supported,
      "bearer_methods_supported" => ["header"],
      "resource_name" => auth.resource_name,
      "resource_documentation" => auth.resource_documentation
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  The URL of the Protected Resource Metadata document of the MCP
  endpoint, or `nil` when the endpoint has no URL (server with no
  authorization).

  The well-known path is inserted before the path of the resource URL:

  ```
  OzMcp.Auth.Metadata.url("https://mcp.example.com/mcp")
  #=> "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"

  OzMcp.Auth.Metadata.url("https://mcp.example.com")
  #=> "https://mcp.example.com/.well-known/oauth-protected-resource"
  ```
  """
  @spec url(String.t() | nil) :: String.t() | nil
  def url(nil), do: nil

  def url(resource_url) when is_binary(resource_url) do
    uri = URI.parse(resource_url)
    path = if uri.path in [nil, "", "/"], do: "", else: uri.path
    URI.to_string(%URI{uri | path: @well_known <> path})
  end

  # A HEAD request carries the headers of the document with no body. The
  # plug writes the empty body itself, because an adapter may not.
  #
  defp body("HEAD", _data), do: ""
  defp body("GET", data), do: data

  # `forward` strips the mount prefix: the plug receives the segments of
  # the resource URL path.
  #
  defp path_info(resource_url) do
    resource_url
    |> URI.parse()
    |> Map.get(:path)
    |> to_string()
    |> String.split("/", trim: true)
  end

  # Public data, no credentials: a wildcard origin is safe here. The
  # allowed request headers are the same list as the preflight of the
  # endpoint: a browser client that sends a header on the metadata
  # request (for example `MCP-Protocol-Version` during the OAuth
  # discovery) needs this list to pass its preflight.
  #
  defp cors(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, HEAD, OPTIONS")
    |> put_resp_header("access-control-allow-headers", Cors.allow_headers())
  end
end
