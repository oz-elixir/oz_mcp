# Authorization

This guide describes the authorization of a server on the HTTP
transport: the token check, the scopes and the answers that a refused
request gets. The guide about the servers gives the reference of the
`authorization` block. The guide about the runtime options gives the
options `resource_url` and `max_token_bytes`.

## What OzMcp does

When the server module declares an `authorization` block, OzMcp is an
OAuth 2.1 resource server. The authorization server issues the tokens.
OzMcp does not issue tokens and it does not read, validate, store, log,
or forward the raw bearer token. The application owns the token check
through the `authenticate/2` callback of a verifier module.

OzMcp does the rest:

  * A request without a valid credential is refused before the body of
    the request is read. The answer carries the status `401` or `400`
    and a `WWW-Authenticate` header.
  * The client learns where the authorization servers are, from the
    `WWW-Authenticate` header and from the Protected Resource Metadata
    document (`OzMcp.Auth.Metadata`).
  * Each session is bound to the principal that created it. Another
    principal cannot use, stream, or end the session.
  * A call of an entity that declares `required_scopes` is refused with
    `403` when the principal does not hold the scopes. The list methods
    show only the entities that the principal can use.
  * The callbacks receive the caller as `ctx.principal`.

A server with no `authorization` block is open: no request is refused
and `ctx.principal` is `nil`.

## The procedure

The setup has five steps:

  1. Write the verifier module with the `authenticate/2` callback (see
     "The verifier").
  2. Add the `authorization` block to the server module (below).
  3. Give `resource_url` to the server in the runtime config (see "The
     audience of the token").
  4. Mount the plug `OzMcp.Auth.Metadata` (see "The metadata document").
  5. Declare `required_scopes` on the entity modules and `authorize/3`
     when the scopes are not enough (see "The scopes of the entities"
     and "The authorize/3 callback").

### The authorization block

The `authorization` block declares that the server is protected:

```elixir
authorization do
  verifier MyApp.AuthVerifier
  authorization_servers ["https://auth.example.com"]
  scopes_supported ["reports:read", "admin"]
  challenge_scopes ["reports:read"]
  filter_by_scope true
  audience_check true
  resource_name "Engineering MCP"
  resource_documentation "https://engineering.example.com/docs/mcp"
end
```

`verifier` and `authorization_servers` are required. The other keys are
optional:

| Key | Value | Job |
|---|---|---|
| `verifier` | module | the module with the `authenticate/2` callback |
| `authorization_servers` | list of URLs | the servers that can issue a token for this MCP server |
| `scopes_supported` | list of scope tokens | the scopes that the server knows. Without the key, the metadata document gives the union of the `required_scopes` of the entity modules |
| `challenge_scopes` | list of scope tokens | the scopes in the `WWW-Authenticate` header when the verifier gives none of its own |
| `filter_by_scope` | boolean (default `true`) | with `false`, the list methods return every entity |
| `audience_check` | boolean (default `true`) | with `false`, the server skips the check that the audience of the token names this server (see "The audience of the token") |
| `resource_name` | string | the name of the resource in the metadata document |
| `resource_documentation` | http(s) URL | the documentation URL of the resource in the metadata document |

### The runtime config

With an `authorization` block, the runtime requires the option
`resource_url` for the server and refuses to boot without it. A server
with no block must not set it. Give it as an option of the
child of the server:

```elixir
{OzMcp,
 server: MyApp.EngineeringServer,
 resource_url: System.fetch_env!("ENGINEERING_MCP_URL"),
 allowed_origins: ["https://app.example.com"]}
```

OzMcp reads the URL one time at boot. A release can read it from the
environment.

### The metadata document

The metadata document tells the client where the authorization servers
are. Mount the plug `OzMcp.Auth.Metadata` outside the MCP endpoint,
because the well-known URL sits at the root of the host:

```elixir
forward "/.well-known/oauth-protected-resource",
  to: OzMcp.Auth.Metadata, init_opts: [instance: MyApp.EngineeringServer]
```

The forward prefix must be the well-known path. For a request to
`/.well-known/oauth-protected-resource/engineering/mcp`, the plug
answers `200` with the document when the path of `resource_url` is
`/engineering/mcp`. Any other path gets `404`. The document of an
instance that does not run gets `503`. The document is public:
no token is checked and the CORS headers are a wildcard.

The URL of the document comes from `resource_url`. The well-known path
is inserted before the path of the endpoint:

```
OzMcp.Auth.Metadata.url("https://mcp.example.com/engineering/mcp")
#=> "https://mcp.example.com/.well-known/oauth-protected-resource/engineering/mcp"
```

The `WWW-Authenticate` header of each refusal carries this URL in the
parameter `resource_metadata`. A client that gets a refusal fetches the
document there.

## The verifier

The verifier is a module with the behaviour `OzMcp.Auth`. The gate calls
`authenticate/2` for each HTTP request, except a CORS preflight, before
the body of the request is read:

```elixir
@callback authenticate(conn :: Plug.Conn.t(), server :: module()) ::
            {:ok, OzMcp.Auth.Principal.t()}
            | {:error, OzMcp.Auth.Challenge.t()
                | :missing_token | :invalid_token | :invalid_request}
```

Return `{:ok, principal}` when the caller is authenticated. Return
`{:error, challenge}` to refuse the request. The refusal becomes an HTTP
status and a `WWW-Authenticate` header (see "The answers").

This example verifies a JWT and builds the principal. OzMcp checks the
audience of the token (see "The audience of the token"). The module
`MyApp.Jwt` is a fake. Use a JWT library, an introspection endpoint, or
trusted headers in a real application:

```elixir
defmodule MyApp.AuthVerifier do
  @behaviour OzMcp.Auth

  alias OzMcp.Auth.Principal

  @impl true
  def authenticate(conn, _server) do
    with {:ok, token} <- OzMcp.Auth.bearer_token(conn),
         {:ok, claims} <- MyApp.Jwt.verify(token) do
      {:ok,
       Principal.new!(
         issuer: claims["iss"],
         subject: claims["sub"],
         client_id: claims["client_id"],
         scopes: String.split(claims["scope"] || "", " ", trim: true),
         audiences: claims["aud"],
         expires_at: claims["exp"]
       )}
    else
      {:error, %OzMcp.Auth.Challenge{} = challenge} -> {:error, challenge}
      _other -> {:error, :invalid_token}
    end
  end

  # Optional: refuse a request that the scopes allow.
  @impl true
  def authorize(%Principal{} = principal, "tools/call", %OzMcp.Pipeline.Bound{
        kind: :tool,
        name: "purge_tickets"
      }) do
    if Principal.scope?(principal, "admin"),
      do: :ok,
      else: {:error, {:insufficient_scope, ["admin"]}}
  end

  def authorize(_principal, _method, _bound), do: :ok
end
```

```elixir
defmodule MyApp.Jwt do
  @moduledoc false

  # A fake. Use a JWT library in a real application.
  def verify("demo-token") do
    {:ok,
     %{
       "iss" => "https://auth.example.com",
       "sub" => "demo",
       "client_id" => "demo-client",
       "aud" => ["https://mcp.example.com/engineering/mcp"],
       "scope" => "reports:read",
       "exp" => 1_799_999_999
     }}
  end

  def verify(_token), do: {:error, :invalid_token}
end
```

Read the credential with `OzMcp.Auth.bearer_token/1`. The function reads
the `Authorization` header only, never the query string. It skips the
spaces after the scheme and it refuses a token over the limit
`max_token_bytes` (default `8192` bytes) with the status `400`.

`Principal.new!/1` raises `ArgumentError` for a wrong value. The fields
of the principal are:

| Field | Value |
|---|---|
| `subject` | the identity of the caller (`sub`). Required, a non-empty string |
| `issuer` | the issuer of the token (`iss`), or `nil` |
| `client_id` | the client of the token, or `nil` |
| `scopes` | the granted scopes, a list of strings |
| `audiences` | the audiences of the token (`aud`), `nil`, one string or a list of strings |
| `claims` | the claims that the application copies from its own check |
| `expires_at` | Unix time in seconds (the `exp` claim), or `nil` |

The principal never holds the raw bearer token. Keep `claims` small:
the session holds the principal and a task keeps a copy of it for its
whole life.

Rules for the verifier:

  * Set `expires_at` (the `exp` claim). OzMcp refuses a principal that
    is already expired. At that time, the `GET` stream of the principal
    ends and the stream of a `POST` request writes a `retry:` hint and
    ends the response. The callback or the task goes on. The client gets
    the later events and the response when it resumes the stream with a
    new token and `Last-Event-ID`. The resume must come within
    `sse_resume_window_ms` of the end of the request. If the clocks of
    the issuer and of the server can differ, subtract a margin from
    `exp`. Use short token lifetimes.
  * Do not forward the received token to another service: token
    passthrough is forbidden.
  * Keep `authenticate/2` fast. It runs for every request. A check that
    needs a remote service must cache its result.
  * OzMcp logs a failure of `authenticate/2` or `authorize/3` by the type
    of the failure and a stacktrace without arguments. It never logs the
    value that you throw, the reason of an exit, or the content of a
    value that you return. For a wrong return value, the log names the
    shape only, for example `tuple :ok of size 2 (second element:
    binary)`. For an unknown shortcut such as
    `{:error, :not_a_challenge}`, the log also names the atom. The text
    of an exception is logged at level `:debug` only. The last-resort
    handler of the router and the guard of the session snapshot write
    the type of the failure and a stacktrace without arguments at level
    `:error` and the full text of the failure at level `:debug`. Do not
    put the token in the text of your own exception and do not run a
    production system at level `:debug`.

### A verifier behind a gateway

A gateway can validate the token and set trusted headers on the request
that it forwards. The verifier reads the headers, never the query
string:

```elixir
defmodule MyApp.GatewayAuth do
  @behaviour OzMcp.Auth

  alias OzMcp.Auth.Principal

  @impl true
  def authenticate(conn, _server) do
    with [subject] <- Plug.Conn.get_req_header(conn, "x-auth-subject"),
         [issuer] <- Plug.Conn.get_req_header(conn, "x-auth-issuer"),
         [scopes] <- Plug.Conn.get_req_header(conn, "x-auth-scopes"),
         [audience] <- Plug.Conn.get_req_header(conn, "x-auth-audience") do
      {:ok,
       Principal.new!(
         issuer: issuer,
         subject: subject,
         scopes: String.split(scopes, " ", trim: true),
         audiences: [audience]
       )}
    else
      _ -> {:error, :missing_token}
    end
  end
end
```

## The audience of the token

The option `resource_url` is the canonical URL of the MCP endpoint. It
identifies this MCP server as a resource to the authorization server and
to the clients (RFC 8707). A token issued for another resource must not
give access here.

OzMcp checks the audience. After the expiry check, the gate compares the
`audiences` of the principal with `resource_url`; one equal entry is
enough (RFC 7519). The compare ignores the case of the scheme and of the
host, removes the default port of the scheme and treats the empty path
and the path `/` as equal. A principal whose audiences hold no equal
entry gets `401` with `error="invalid_token"` and
`error_description="token audience mismatch"`. A principal without
audiences (`nil`) is refused too: set `audiences` of the principal (the
`aud` claim). If your verifier checks the audience itself, set
`audience_check false` in the `authorization` block.

The rules of `resource_url`:

  * Required for a server with an `authorization` block, refused for a
    server without one.
  * A canonical URI: scheme `https`, or `http` for a loopback host
    (`localhost`, `127.0.0.1`, `::1`) only. No query, no fragment, no
    user info, no slash at the end.
  * OzMcp stores the scheme and the host in lower case. The path keeps
    its case.
  * Serve the endpoint behind TLS at this URL. A proxy that changes the
    host or the scheme is invisible from the inside, so the URL is never
    guessed from the request.

## The authorize/3 callback

The callback `authorize/3` is optional. It can refuse a request that the
scopes allow, for example a tool that only some callers can use. The
callback runs for the JSON-RPC `POST` only, after the request is valid.
It does not run for `GET` (open a stream), for `DELETE` (end a session),
for the lists, or for the answer of the client to a request of the
server. For `GET` and `DELETE`, OzMcp checks that the session belongs to
the principal. To refuse a `GET` or a `DELETE` by scope, refuse the
token in `authenticate/2`: the connection holds the method.

The third argument is a `t:OzMcp.Pipeline.Bound.t/0` struct: the entity
the request names, found by the bind stage of the pipeline. Read
`bound.kind` (the kind of the entity), `bound.name`, `bound.arguments`,
`bound.task` and `bound.params`:

| `bound.kind` | Methods | `bound.name` |
|---|---|---|
| `:tool` | `tools/call` | the name of the tool |
| `:resource` | `resources/read`, `resources/subscribe` | the uri of the resource |
| `:template` | the same methods, when the uri matches a template | the uri of the resource |
| `:prompt` | `prompts/get` | the name of the prompt |
| `:completion` | `completion/complete` | `nil` |
| `:task` | `tasks/get`, `tasks/list`, `tasks/cancel`, `tasks/result` | the task id, when the method carries one |
| `:none` | `initialize`, `ping`, `resources/unsubscribe`, the lists, `logging/setLevel`, a notification | `nil` |

`bound.task` holds the metadata of a task-augmented `tools/call`
(`%{ttl: ttl | nil}`) and `bound.params` always holds the params of the
request.

The example above refuses `tools/call` for the tool `purge_tickets`
without the scope `admin`. The return values are:

| Return | Answer |
|---|---|
| `:ok` | the request goes on |
| `{:error, {:insufficient_scope, scopes}}` | `403`, the header names the scopes of the principal and `scopes` |
| `{:error, {:insufficient_scope, scopes, description}}` | `403`, the header names the scopes of the principal and `scopes` and the description |
| `{:error, :forbidden}` | `403` without a scope challenge |

An empty list of scopes makes the header name the `challenge_scopes` of
the server next to the scopes of the principal. For `initialize`, the
callback runs before the session exists: a refused `initialize` creates
no session.

A raise, a throw, an exit, or a return value of another shape is a
defect of the application. The request gets a server error, never a
pass.

## The answers

A protected server that does not run answers `503`. The gate never lets
a request pass when the check cannot run.

A refused request gets a JSON-RPC error body with no detail of the
refusal. The refusal travels in the `WWW-Authenticate` header:

| Status | Error parameter | When |
|---|---|---|
| `401` | no error parameter | no usable bearer credential: no header, a scheme other than `Bearer`, no token after the spaces |
| `401` | `invalid_token` | the verifier returned the challenge, or the principal is already expired |
| `400` | `invalid_request` | a malformed request: more than one `Authorization` header, a token over the limit, a malformed token |
| `403` | `insufficient_scope` | the principal does not hold the required scopes, or `authorize/3` refused the request |

The header holds these parameters, each only when it has a value:

| Parameter | Value |
|---|---|
| `error` | the error parameter of the table |
| `error_description` | the description of the challenge, cut to 200 characters |
| `scope` | the scopes to ask for: the scopes of the challenge, else the `challenge_scopes` of the server. A `403` of a protected route holds the union: the scopes of the principal, then the scopes of the challenge that are not in the list |
| `resource_metadata` | the URL of the metadata document |

This is an example of a `401` answer:

```
HTTP/1.1 401 Unauthorized
www-authenticate: Bearer error="invalid_token",
  scope="reports:read",
  resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/engineering/mcp"
```

A client that gets a refusal fetches the metadata document and asks the
authorization server for a token with the scopes of the `scope`
parameter. A client that gets no `scope` parameter asks for all the
`scopes_supported` of the server.

The order of the checks of a request is: the CORS origin, the
authentication, then the route. An unsupported method on a protected
server gets `401` and `405` with a valid token. A CORS preflight
(`OPTIONS`) carries no credentials and it is not checked.

Each refusal also emits the event `[:oz_mcp, :auth, :refused]` of the
telemetry (see the guide about telemetry): the event holds the stage
and the reason of the refusal and never a token, a subject, or a scope
string.

The scope check of an entity runs after the checks of the request
itself: a call for an unknown tool, a bad `arguments`, or a wrong task
field gets its JSON-RPC error, not the `403`. So the answer to a caller
without the scopes can tell that an entity exists, or name the arguments
of a prompt. The check of `authorize/3` runs after the scope check. The
method `resources/unsubscribe` is not checked: a caller can always
remove its own subscription.

The check of the owner of a session runs before the server starts a
session again from its snapshot: a session id that belongs to another
principal gets the same `404` as an unknown session id and no session
starts for it.

## The scopes of the entities

Each kind of entity can declare the scopes that a caller needs. Declare
`required_scopes` in the block of the entity:

```elixir
tool "delete_ticket" do
  title "Delete a ticket"
  description "Delete a ticket of the team"

  input_schema %{
    type: "object",
    properties: %{id: %{type: "string", minLength: 1}},
    required: ["id"]
  }

  required_scopes ["tickets:write", "tickets:delete"]
end
```

The four kinds have the macro: `tool`, `resource`, `template` and
`prompt`. A list means "all of these scopes": the principal must hold
every scope of the list. The `scope` parameter of the `403` names the
scopes that the principal holds and all the required scopes of the
entity.

The list methods `tools/list`, `resources/list`,
`resources/templates/list` and `prompts/list` show only the entities
that the principal can use. This is the filter:

  * The filter runs when `filter_by_scope` is `true` (the default) and a
    module of the kind declares scopes. With `false`, the lists return
    every entity and the calls alone obey the scopes.
  * The filter reads all the entities of the kind, removes the entities
    that the principal cannot use and cuts the pages after the filter.
    The cursor is an opaque string that names a page of the filtered
    list. If the scopes of the token change between two calls, items can
    move between pages and the filtered list can get shorter: a cursor
    that names a page after the new last page is then refused with the
    error `-32602`.
  * An entity that a caller cannot use still exists: a call gets `403`.
    The filter is for relevance, it is not a secret.

A map from a module with `dsl?: false` carries `required_scopes` like
a struct: the boot of the instance reads the key and checks it and the
key never reaches the client. The guides of the
entities give the details of each kind.

The filter reads the scopes from the entries, which the catalog reads
one time at the boot. A module has no other way to declare them.

When the server sets no `scopes_supported`, the metadata document gives
the sorted union of the `required_scopes` of the entries. Set
`challenge_scopes` to keep the first request of a client small: a client
that gets no `scope` parameter asks for all the `scopes_supported`.

## The subscriptions

A `resources/subscribe` for a resource that declares `required_scopes`
puts those scopes on the subscription of the session. At each later
request of the session, the framework compares the scopes of the token
of that request with the scopes of each subscription and it ends every
subscription whose scopes the token does not cover. A request is a
`POST` of the session, or the open of a `GET` stream (a fresh one, or
one that reconnects with `Last-Event-ID`). The subscription to
a resource with no `required_scopes` never ends this way.

The limits of this check:

  * A `GET` stream that stays open keeps the token of its open: a scope
    that the server takes back while the stream is open is seen at the
    next request (a new `POST`, or the open of the next stream after a
    poll close).
  * The server learns the scopes of a token only from a request. A token
    that is revoked, or that expired, between two requests is not seen:
    the next request of the session is.
  * A request that an earlier stage refuses (an expired token that gets
    `401`, a call that gets `403` for another reason) is not seen.
  * `authorize/3` does not run again for a subscription.
  * The end of a subscription sends nothing to the client. A client that
    gets the scopes back must subscribe again.
  * A subscription that a snapshot restored from a store of before this
    check carries no scopes: it has no check until the client
    subscribes again.

Each end emits the event `[:oz_mcp, :subscription, :dropped]` of the
telemetry, with the count of the subscriptions that the check ended
(see the guide about telemetry).

## The scopes of a task

A task keeps the `required_scopes` of the tool that created it. The
methods `tasks/get`, `tasks/result` and `tasks/cancel` check these scopes
against the principal of the request. A principal without them gets
`403`. A `tasks/list` page holds only the tasks whose scopes the
principal has. A token that lost a scope after the creation of the task
can no longer read the task.

## The principal in the callbacks

The map `ctx` of a callback carries the caller:

```elixir
@impl true
def call(ctx, %{"name" => "whoami", "arguments" => _}) do
  {:ok, %{content: [%{type: "text", text: ctx.principal.subject}]}}
end
```

`ctx.principal` is an `OzMcp.Auth.Principal`, or `nil` when the server
has no authorization. The session holds the principal key
`{issuer, subject}` of the caller that created it. Another principal
cannot use, stream, or end the session: its requests get `404` or the
JSON-RPC error of an unknown session.

The option `max_sessions_per_principal` limits the number of the
sessions of one principal (default `100`; the value `nil` sets no
limit). An `initialize` over the limit ends the idle session of the
principal with the oldest activity and starts the new one; when no
session is idle, it gets `429` with the JSON-RPC error `-32000 "too
many sessions"` (see the runtime options guide). The limit covers
a server with an `authorization` block only: a server with no
authorization has no principal.

## Revoke the access of a principal

When the application revokes the access of a principal, do two things in
this order:

  1. Refuse the token of the principal in `authenticate/2`.
  2. Call `OzMcp.Sessions.terminate_principal/2` with the server module
     and the principal, or its key `{issuer, subject}`:

```elixir
{:ok, ended} = OzMcp.Sessions.terminate_principal(MyApp.EngineeringServer, principal)
```

Step 1 stops a new session and a new request. Step 2 ends the sessions
that exist. The open streams, the requests in flight and the tasks of
these sessions end. If the application does step 2 only, the client can
start a new session with the old token.

The result is `{:ok, ended}`, with the ids of the ended sessions. The
result `{:ok, []}` can also mean that a snapshot module does not
keep the principal key of its sessions. Each call gives one event of
the telemetry, with the count of the sessions that the call ended (see
the guide about the telemetry).

Step 2 works with the default PubSub module and with a custom one:
`terminate_principal/2` reads the sessions of the server, not the
subscribers of a topic. It ends the sessions of the local node only.
A cluster must call it on each node (see the guide
[Run many nodes](cluster.md)).

## stdio

A server on the stdio transport uses none of this, even with an
`authorization` block. The client owns the process of the server, so
there is no principal, no scope check and no filter on the lists. The
lists are complete and every entity is callable.
