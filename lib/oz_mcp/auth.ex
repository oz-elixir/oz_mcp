defmodule OzMcp.Auth do
  @moduledoc """
  Contract for the token check of a protected MCP server.

  When the server module declares an `authorization` block, OzMcp is an
  OAuth 2.1 resource server. OzMcp does not read, validate, store, log,
  or forward the raw bearer token. The application owns the whole check
  through the `authenticate/2` callback: it can verify a JWT, call an
  introspection endpoint (RFC 7662), or trust a header set by a gateway.
  OzMcp does the rest: it refuses a request without a valid credential
  before the body is read, it tells the client where the authorization
  servers are (see `OzMcp.Auth.Metadata`), it binds each session to the
  principal that created it and the callbacks receive the caller as
  `ctx.principal`. The guide about the authorization gives the whole
  behaviour: the `authorization` block, the answers, `authorize/3`, the
  scopes of the entities and their filter and the revocation of a
  principal.

  ## Scopes in the DSL

  Declare the scopes that an entity needs with `required_scopes` in its
  block. OzMcp refuses a call without them with `403` and an
  `insufficient_scope` challenge and the list methods show only the
  entities that the principal can use. The cursor of a filtered list is
  an opaque string. If the scopes of the token change between two calls,
  items can move between pages and the filtered list can get shorter: a
  cursor that names a page after the new last page is then refused with
  the error `-32602`. The guide about the authorization gives the limits
  of the filter.

  ## The duties of the application

  * Set `audiences` of the principal (the `aud` claim) and `expires_at`
    (the `exp` claim). OzMcp refuses a principal whose audiences hold no
    entry for the `resource_url` of the server and a principal that is
    already expired. If your verifier checks the audience itself, set
    `audience_check false` in the `authorization` block.
  * Do not forward the received token to another service: token
    passthrough is forbidden.
  * To end the access of a principal that you revoke, refuse its token in
    `authenticate/2`. Then call `OzMcp.Sessions.terminate_principal/2`.
  * Keep `authenticate/2` fast: it runs for every request. A check that
    needs a remote service must cache its result.
  * Keep the `:claims` of a principal small: a task keeps a snapshot of
    the principal for its whole life.
  * Do not put the token in the text of your own exception: the log of a
    failure names the type of the failure, never a value of the
    application.

  Run the server behind TLS and configure the runtime option
  `:resource_url` with the public URL of the endpoint.

  A server with no `authorization` block is open. A server on the stdio
  transport (`OzMcp.Transport.Stdio`) uses none of this, even with an
  `authorization` block: the client owns the process of the server.

  ## Setup

      defmodule MyApp.McpServer do
        use OzMcp.Config.Server

        server_info do
          name "my-app"
          version "1.0.0"
        end

        authorization do
          verifier MyApp.AuthVerifier
          authorization_servers ["https://auth.example.com"]
          scopes_supported ["files:read", "files:write"]
          challenge_scopes ["files:read"]
        end
      end

      defmodule MyAppWeb.PlugRouter do
        use Plug.Router
        plug :match
        plug :dispatch

        forward "/mcp",
          to: OzMcp.Router, init_opts: [instance: MyApp.McpServer]

        forward "/.well-known/oauth-protected-resource",
          to: OzMcp.Auth.Metadata, init_opts: [instance: MyApp.McpServer]
      end

      # Serve the router with Bandit, behind TLS:
      # {Bandit, plug: MyAppWeb.PlugRouter, port: 4000}
      {OzMcp,
       server: MyApp.McpServer,
       resource_url: "https://mcp.example.com/mcp",
       allowed_origins: ["https://app.example.com"]}

  The `resource_url` is the canonical URL of the MCP endpoint
  (RFC 8707). It can be read from the environment of a release.

  The router takes the `allowed_origins` from the runtime config. The
  plug option `allowed_origins` of `OzMcp.Router` overrides the list.

  The guide about the authorization shows a verifier on a JWT library
  and a verifier behind a gateway.
  """

  alias OzMcp.Auth.{Challenge, Principal}

  @doc """
  Called for each HTTP request except `OPTIONS`.

  The callback reads the credentials from the connection (usually with
  `bearer_token/1`), validates them and returns the principal.

  Return `{:ok, principal}` when the caller is authenticated. Return
  `{:error, challenge}`, or one of the shortcut atoms which become a
  challenge, to refuse the request. The refusal becomes an HTTP status
  and a `WWW-Authenticate` header.
  """
  @callback authenticate(conn :: Plug.Conn.t(), server :: module()) ::
              {:ok, Principal.t()}
              | {:error, Challenge.t() | :missing_token | :invalid_token | :invalid_request}

  @doc """
  Called after the JSON-RPC request is valid, when the server declares
  it.

  The third argument is a `t:OzMcp.Pipeline.Bound.t/0`: the entity the
  request names, found by the bind stage of the pipeline. Read
  `bound.kind` (the kind of the entity: `:tool`, `:resource`,
  `:template`, `:prompt`, `:completion`, `:task` or `:none`),
  `bound.name`, `bound.arguments`, `bound.task` and `bound.params`. For
  a method that names no entity (`initialize`, `ping`, the lists,
  `logging/setLevel`, a notification), `bound.kind` is `:none` and
  `bound.params` holds the params of the request.

  Return `:ok` to allow the request. Return
  `{:error, {:insufficient_scope, scopes}}` or
  `{:error, {:insufficient_scope, scopes, description}}` to answer `403`
  with a scope challenge. The `scope` of the challenge holds the scopes
  of the principal and the scopes that are missing. When `scopes` is an
  empty list, the header names the `challenge_scopes` of the server next
  to the scopes of the principal. Return `{:error, :forbidden}` to
  answer `403` without a scope challenge.

  For `initialize` the callback runs before the session exists: a refused
  `initialize` creates no session and the callback never receives a
  session id.

  An `initialize` with a refused scope gets `403`, even when it carries an
  `Mcp-Session-Id` header. The scope check runs first. An allowed
  `initialize` with that header gets `400`, from the session check.

  The callback runs for the JSON-RPC `POST` only. It does not run for `GET`
  and `DELETE`: the owner check of the session covers them.
  """
  @callback authorize(
              principal :: Principal.t(),
              method :: String.t(),
              bound :: OzMcp.Pipeline.Bound.t()
            ) ::
              :ok
              | {:error, {:insufficient_scope, [String.t()]}}
              | {:error, {:insufficient_scope, [String.t()], description :: String.t()}}
              | {:error, :forbidden}

  @optional_callbacks authorize: 3

  @default_max_token_bytes 8192
  @scope_token ~r/\A[!#-\[\]-~]+\z/
  @token_format ~r/\A[A-Za-z0-9\-._~+\/]+=*\z/

  @loopback_hosts ["localhost", "127.0.0.1", "::1"]

  @doc """
  True for a loopback host: `localhost`, `127.0.0.1`, or `::1`. `http` is
  allowed for these hosts only. The comparison ignores the case.
  """
  @spec loopback_host?(term()) :: boolean()
  def loopback_host?(host) when is_binary(host), do: String.downcase(host) in @loopback_hosts
  def loopback_host?(_host), do: false

  @doc """
  True when the value matches the RFC 6749 scope-token syntax:
  printable ASCII, without space, double quote and backslash.
  """
  @spec scope_token?(term()) :: boolean()
  def scope_token?(value), do: is_binary(value) and Regex.match?(@scope_token, value)

  @doc """
  Read the bearer token from the `Authorization` header of the request.
  Never reads a token from the query string.

  Returns:

  - `{:ok, token}` for a well-formed bearer token,
  - `{:error, challenge}` with no error parameter for an absent header, a
    scheme other than `Bearer`, or a header with no token after the
    spaces (RFC 6750, section 3.1),
  - `{:error, challenge}` with the `invalid_request` error for more than
    one `Authorization` header, a token over the maximum size, or a
    malformed token.

  All spaces after the scheme are skipped: `"Bearer  abc"` gives the
  token `"abc"`. A tab is not a space: it stays in the token and makes it
  malformed.

  The maximum size in bytes is #{@default_max_token_bytes}. The gate
  copies the runtime option `:max_token_bytes` of the server to the
  connection and this function reads it. The option `max_bytes:` here
  overrides both. A verifier that does not call this function is not
  limited.
  """
  @spec bearer_token(Plug.Conn.t(), keyword()) :: {:ok, String.t()} | {:error, Challenge.t()}
  def bearer_token(conn, opts \\ []) do
    max_bytes =
      Keyword.get(opts, :max_bytes) ||
        conn.private[:oz_mcp_max_token_bytes] ||
        @default_max_token_bytes

    case Plug.Conn.get_req_header(conn, "authorization") do
      [] ->
        {:error, Challenge.missing_token()}

      [value] ->
        parse_authorization(value, max_bytes)

      _several ->
        {:error, Challenge.invalid_request("more than one authorization header")}
    end
  end

  defp parse_authorization(value, max_bytes) do
    case String.split(value, " ", parts: 2) do
      [scheme, rest] ->
        if String.downcase(scheme) == "bearer",
          do: check_token(String.trim_leading(rest, " "), max_bytes),
          else: {:error, Challenge.missing_token()}

      _ ->
        {:error, Challenge.missing_token()}
    end
  end

  # No token after the spaces: the request has no credentials
  # (RFC 6750, section 3.1).
  #
  defp check_token("", _max_bytes), do: {:error, Challenge.missing_token()}

  defp check_token(token, max_bytes) do
    cond do
      byte_size(token) > max_bytes ->
        {:error, Challenge.invalid_request("token too long")}

      not Regex.match?(@token_format, token) ->
        {:error, Challenge.invalid_request("malformed token")}

      true ->
        {:ok, token}
    end
  end
end
