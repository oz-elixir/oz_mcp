# HTTP transport

This guide describes the Streamable HTTP transport of `OzMcp.Router`.
The guide about the runtime options gives the options of the runtime
config. This guide describes the behavior of a mounted server on HTTP.

## Mount the server

`OzMcp.Router` is a plug. Mount it at one path of your plug router with
`forward`:

```elixir
forward "/mcp", to: OzMcp.Router, init_opts: [instance: MyApp.McpServer]
```

The `instance` option names the instance: the name that you gave to
`{OzMcp, ...}`, which is the server module by default. The option
`server:` also works and gives the same result when the instance has the
default name. The endpoint lives on this single path. A request to another path of your router gets the
answer of your own router, not of `OzMcp.Router`.

## The HTTP server

The framework talks to the HTTP server through `Plug.Conn` and
`Plug.Conn.Adapter` only. Two servers are supported. CI runs the
end-to-end suite on each one:

| Server | Tested version | CI job | Mount |
|---|---|---|---|
| Bandit | `1.15.0` | `test-e2e` | `{Bandit, plug: MyApp.Router, port: 4000}` |
| Cowboy, through `plug_cowboy` | `cowboy 2.21.0`, `plug_cowboy 2.9.0` | `test-e2e-cowboy` | `{Plug.Cowboy, scheme: :http, plug: MyApp.Router, port: 4000, protocol_options: [idle_timeout: 300_000, reset_idle_timeout_on_send: true]}` |

The options of the Cowboy mount: with its defaults, Cowboy closes a
connection after 60 s with no bytes from the client, also while a
response streams. The writes of the server do not hold the connection:
a write resets the idle timer only when `reset_idle_timeout_on_send` is
`true`. So:

  * `reset_idle_timeout_on_send: true` keeps an open stream alive while
    the heartbeats write. `sse_heartbeat_ms` must stay under
    `idle_timeout`.
  * `idle_timeout` must be longer than the longest request with no
    stream: a request with no stream writes nothing until its answer.
    Set a value above `request_timeout_ms`, or run long work as a
    streaming request.

### The contract with the host server

The framework needs these things from the server. They are the contract
of `Plug.Conn.Adapter` and of the process model:

  1. `Plug.Conn.chunk/2` writes a chunk of a chunked response, or
     returns an error when the connection is closed.
  2. The loop of a stream owns the connection until it returns the conn.
  3. A message that the server sends to the request process stays in
     the mailbox: no `receive` of the framework takes it.
  4. The server finds a closed connection in one of two ways: a write
     fails, or the server ends the request process.
  5. The end of the request process ends the request that the process
     owns (a method with no stream of its own: the lists,
     `resources/subscribe`, `resources/unsubscribe`, `logging/setLevel`,
     `tasks/get`, `tasks/list`, `tasks/cancel`). A method with a stream
     (`tools/call`, `prompts/get`, `resources/read`,
     `completion/complete`, `tasks/result`) runs its callback in a
     worker of the framework: the end of the request process makes the
     stream a hand-off and the callback goes on. A task does not
     depend on the request process.
  6. The server can run the next request of a connection in the same
     process. The framework cancels its timers on every exit.

A server that is not in the table can work if it respects the six
points. Nobody tests it.

### What a disconnect does

A disconnect is not a cancel: the callback of a request goes on and
its later messages and its response reach the client through the event
log of the stream. The table gives the measured result of each case,
per server. The end-to-end suite proves each row on both servers.

| Case | Bandit | Cowboy |
|---|---|---|
| A streaming `POST`: the callback after a close | the callback goes on; the response is in the event log of the stream and a resume with `Last-Event-ID` reads it | the same |
| A `POST` whose response stays JSON: the callback after a close | the callback goes on and the session stays valid (a `ping` answers). The callback runs in a process of the framework, which no server owns | the same |
| A request to the client during a close | the request stays open; the client resumes the stream with `Last-Event-ID`, answers there and the callback ends with the answer | the same |
| A `tasks/result` stream after a close | the task stays `working` and a later wait reads the outcome | the same |
| How the server finds a closed `GET` stream | a failed write: the first heartbeat that fails. The first write after the close can still fit in the TCP buffer, so the detection takes one to two heartbeat intervals | the end of the process of the request, at once, with no write |
| An open stream with the default options of the server | the stream stays open as long as the client and the server run | the listener closes the connection after 60 s with no bytes from the client; the heartbeats do not hold it without `reset_idle_timeout_on_send: true` (the mount of the table sets it) |

Every user callback of the transport runs in a process of the
framework: the worker of the request (also when the response stays
JSON), or the process of its task. A callback with `isolation: :inline`
runs in that process too, not in the process of the request. So the
rows above hold for each method with a callback, on both servers: the
end of the process of the connection does not stop a callback. The
end of the process of the connection stops only the request that the
process owns (a method with no stream of its own, see the point 5 of
the contract).

## Two servers on two paths

Mount `OzMcp.Router` one time per server:

```elixir
defmodule MyApp.HttpRouter do
  use Plug.Router

  plug Plug.Logger
  plug :match
  plug :dispatch

  forward "/engineering/mcp", to: OzMcp.Router, init_opts: [instance: MyApp.EngineeringServer]

  # This mount overrides the list of the runtime.
  forward "/marketing/mcp",
    to: OzMcp.Router,
    init_opts: [instance: MyApp.MarketingServer, allowed_origins: ["https://marketing.example.com"]]

  # The plug answers the path of the resource_url after this prefix
  # (RFC 9728): /.well-known/oauth-protected-resource/engineering/mcp
  forward "/.well-known/oauth-protected-resource",
    to: OzMcp.Auth.Metadata,
    init_opts: [instance: MyApp.EngineeringServer]

  match _ do
    send_resp(conn, 404, "not found")
  end
end
```

Each mount serves one server with its own sessions, its own limits and
its own event logs. A session of one path does not exist on the other
path. For a protected server, mount `OzMcp.Auth.Metadata` at the
well-known path of the host. The plug answers the path of the
`resource_url` after the prefix. The guide about the authorization
gives the full procedure.

## The origins of the browsers

The option `allowed_origins` of the child of the server is the list of
the origins of the browsers. Without it, the list is empty:

```elixir
{OzMcp, server: MyApp.McpServer, allowed_origins: ["https://app.example.com"]}
```

`OzMcp.Router` uses this list for every request that carries an
`Origin` header. The plug option `allowed_origins` overrides the list
of the runtime for one mount, as the marketing mount above shows.

Each element of the list must be a non-empty string. The runtime
refuses the value `"*"` at boot: it is not a wildcard and the router
compares each origin as a string.

A request with no `Origin` header passes the check. A client that is
not a browser sends no header. The `OPTIONS` preflight obeys the same
rule. An origin that the server does not allow gets `403` with an empty
body.

The answer of a request that carried an allowed origin carries the
CORS headers: the origin itself, the expose list (`mcp-session-id`,
`mcp-protocol-version`, `www-authenticate`) and `Vary: Origin`. The
answer of a preflight also names the methods (`GET, POST, DELETE,
OPTIONS`) and the request headers (`*, authorization`). The Fetch
standard does not let the wildcard cover the `Authorization` header:
its name is listed, so a browser client can send its credential. The
expose list tells the browser which response headers the JavaScript
client may read.

## The HTTP methods

| Method | Job |
|---|---|
| `POST` | the requests and the notifications of the client |
| `GET` | the server-to-client event stream of the session |
| `DELETE` | the end of the session |
| `OPTIONS` | the CORS preflight |

A request with another method gets `405` with an `Allow` header that
names `GET, POST, DELETE, OPTIONS`. The body is the JSON-RPC error
envelope. On a protected server an unsupported method gets `401`
before the route check and `405` with a valid token.

## The request headers

| Header | Rule |
|---|---|
| `Mcp-Session-Id` | the id of the session. Required for every request after `initialize`. An `initialize` with this header gets `400`. The value must be 1 to 128 bytes of visible ASCII. Another value, or two headers, gets `400` |
| `MCP-Protocol-Version` | the protocol version of the client. An unsupported version gets `400`. Two or more header lines get `400`, also when the values are equal. A version that differs from the version of the session gets `400`. `initialize` skips the check. `ping` and `DELETE` compare the version too |
| `Accept` | the server reads all the `Accept` headers and parses each media range with its `q` value. The ranges must match `application/json` and `text/event-stream`. The ranges `*/*`, `application/*` and `text/*` match. The most specific matching range decides (`text/event-stream;q=0, */*` refuses SSE); a `q=0` there refuses the type. A missing value, or a value that does not match, gets `406` |
| `Content-Type` | `application/json` for a `POST`. Another value, or no value, gets `415` |

## The order of the checks

A `POST` request passes the stages of the pipeline in this order:
decode, authenticate, envelope, session, version, bind, authorize and
execute. The stdio transport uses the same stages. The first refusal
gives the answer and the later stages do not run. In detail, the
steps are:

1. The instance: an instance that does not run gets `503`, before every other check
2. The host: a `Host` header that the list `allowed_hosts` does not name gets `403` (`:any`, the default, accepts every host)
3. The origin: a browser origin that the server does not allow gets `403`
4. The authentication: no valid credential gets `401` (or `400` for a malformed one)
5. The headers: `400`, `406` or `415`
6. The JSON-RPC envelope and the shape of the params: `400`, or the JSON-RPC error of the shape
7. The scopes of `initialize`: `403`
8. The session id: `400` without the header or with an invalid value
9. The protocol version: `400`
10. The restore of a session that is only in the snapshot store: `404` for a snapshot of another principal; a session limit ends an idle session and gives `429` when no session is idle
11. The state of the session: `404` for an unknown session or a session of another principal
12. The lookup of the entity (the tool, the resource, the template or the prompt) and the check of its arguments: the JSON-RPC errors `-32602` and `-32002`
13. The required scopes of the entity: `403`
14. The `authorize/3` callback of the application: `403`

The lookup of the entity runs after the session checks. A caller
without a valid session gets the same answer for a known entity and for
an unknown entity: the refusals of the session tell the caller nothing
about the entities of the server.

A `ping` carries the session id like every request after `initialize`:
an unknown session or a session of another principal gets `404` and a
`ping` of the owner is answered. The owner can send `ping` before it
sent `notifications/initialized`. A `ping` whose `MCP-Protocol-Version`
differs from the version of the session gets `400`.

The `GET` and the `DELETE` run the same steps without the envelope and
the entity. The session id runs before the protocol version, like a
`POST`: equal mistakes get the same answer on the three methods. A
`DELETE` reads the session state, so the owner check and the compare of
the version run for an open server too.

The `session` span of the telemetry covers the life of the session: a
`DELETE` gives the `:stop` event with the reason `terminated` and the
end of an idle session gives the reason `idle`. The guide about the
telemetry lists the events and the reasons of the end.

## The answers

A request gets `200`. The body is JSON. When the callback of the
request sends messages to the client, the response becomes an event
stream. The methods with a possible stream are `tools/call`,
`resources/read`, `prompts/get`, `completion/complete` and
`tasks/result`. A response of `initialize` carries the
`mcp-session-id` header.

Each message of a `POST` gives one `request` span of the telemetry,
with the status of the answer and the code of a refusal: the guide
about the telemetry lists the events and their metadata.

A notification of the client, or the answer of the client to a request
of the server, gets `202` with no body. A second
`notifications/initialized` on an initialized session gets `202` too:
the server ignores it.

A message with a `notifications/*` method and an `id` is a request and
the server handles no request with such a method: it gets `200` with
the JSON-RPC error `-32601 "method not found"` and its `id` echoed.

### The reuse of a request id

The spec says that a request id must not be used again in the same
session. The client has this duty. The server refuses an id that is
**running** (`-32600`, `"request id already in use"`). It does not
remember an id after the answer. A client that sends the same id again
after the answer gets a normal answer.

## The stream of a POST request

When the callback of a `POST` request sends messages to the client
(`tools/call`, `resources/read`, `prompts/get`, `completion/complete`,
`tasks/result` can), the messages belong to the request: the response
is upgraded to `text/event-stream`, the messages are written as events
and the response of the request is the last event of the stream. The
head of the stream carries `cache-control: no-cache` and the CORS
headers of the request.

Each event carries an id of the form `<stream>:<n>` and is kept in the
event log of the session. The stream starts with a priming event
(`<stream>:0`, empty `data`), so the client has an id to resume from.

The upgrade is lazy. A request whose callback sends nothing gets the
plain `application/json` response. The head of the response is
committed when the first message is written, or earlier when the
callback calls the heartbeat with the option `start: true` (for a
request that can wait for a long time and sends nothing, such as a
long `tasks/result` wait). While the stream waits idle, the server
writes `: heartbeat` comments with the interval `sse_heartbeat_ms`; a
client ignores them.

The response counts as streamed only when the connection already
carries the stream (an event, a heartbeat with `start: true`, or a
resumer that took it over with an event): a stream that a resumer took
over before any event has no response on the old connection and the
caller of the request sends the plain response.

A client that loses the connection resumes with a `GET` and
`Last-Event-ID: <stream id>:<n>`. The `GET` becomes the resumer of the
stream: it sends the retained events of the stream after `n`, then the
live events of the stream and it ends after the response of the
request. It does not carry the notifications of the session. When the
stream is still open, the resumer takes it over: the old connection
gets no more events. An event of a `POST` stream never goes to a `GET`
stream of the session: the client gets the events by resuming the
`POST` stream.

The framework does not cancel the request when the connection ends
and the end of the process of the connection makes the stream a
hand-off: the callback goes on and its later messages and its
response go to the event log of the session, under the ids of the
stream, for a client that resumes.

The stream closes for real at the expiry of the principal of the
request and at `sse_max_stream_ms`: it writes a `retry:` hint and ends
the response while the callback goes on. The later events and the
response go to the event log and a client that resumes with
`Last-Event-ID` gets them. A resumed `POST` stream that is still open
closes the same way and the client resumes it again.

The session is the only authority for the ids: it gives each event its
id and it gives the response the last id. The one exception is a
request with no session: no other process can send an event on its
stream and the stream numbers its own events. When the session cannot
answer at the end of a started stream (it stopped, it does not exist,
or the call times out), the response is written as the last event with
no `id:` line, so the client gets the response on the connection that
carries the stream. A request id that is not a string or an integer (a
notification) has no stream target: the messages of such a request go
to the `GET` stream of the session.

## The GET stream

A `GET` request opens the event stream of the session. The stream
starts with a `retry:` hint and a priming event with an empty `data`
field. The id of the priming event is the first position of the client.
Each event of the stream carries an id of the form `g.<stream>:<n>`:
the part before the colon names the stream and the number after it is
the position of the event in the stream. The client treats the id as
opaque text.

While the stream is idle, the server writes `: heartbeat` comments.
The interval is the option `sse_heartbeat_ms`. The value `:infinity`
stops the heartbeat.

The server does not get a message when a client closes the connection.
The way it finds the gone client depends on the server. On Bandit, a
write to the stream fails. A heartbeat is such a write. On Cowboy, the
close ends the process of the request at once and the session sees the
end with no write.

On Bandit, the first write after the close can still fit in the TCP
buffer. The detection then takes one to two heartbeat intervals. With
`:infinity`, only the write of the next event finds the close. Until
the detection, the stream is still open for the server. It keeps its
slot and the session does not start its idle timer.

The section "The HTTP server" gives the table of the two servers.

A `GET` that would go over `max_streams_per_session` does not get
`429`. The session ends its **oldest** `GET` stream and opens the new
one. This is true for a `GET` with no `Last-Event-ID` and for the resume
of a stream that is not open. The ended stream writes a last `retry:`
hint and the session keeps its events for `sse_resume_window_ms`. A
client that still uses this stream connects again with `Last-Event-ID`
and gets the events that it missed. The resume of a stream that is
still open takes over that stream and ends no other stream.

With the option `sse_max_stream_ms` a stream closes itself after
this time: it writes a final `retry:` hint and ends the response. The
client waits, connects again with the last event id that it saw and
the server replays the events of the gap from the log. The option
applies to a `GET` stream, to the stream of a `POST` request and to the
resume of a `POST` stream. A resumed `POST` stream that is still open
closes the same way and the client resumes it again.

At the expiry of the principal of the request, the stream of a `POST`
request closes too: it writes a `retry:` hint and ends the response
(see the authorization guide). The callback goes on. A client resumes at
once with its `Last-Event-ID` and a new token: the resume gives the
later events and the response of the request. The resume must come
within `sse_resume_window_ms` of the end of the request.

When the process of the session stops, each open stream of the session
writes a `retry:` hint and ends. The client connects again with its
`Last-Event-ID`.

## Resume with Last-Event-ID

A client that reconnects sends the id of the last event that it saw in
the `Last-Event-ID` header. The session process gives the id of each
event and no two events of one stream have the same id. The id tells
the stream of the event: an id of a `GET` event has the form
`g.<stream>:<n>`, an id of a `POST` stream has the form `<stream>:<n>`.
Two kinds of resume exist:

  * An id of a `GET` event (`g.<stream>:<n>`). The new `GET` takes the
    id of that stream, replays only the events of this stream after
    `n` — never an event of another stream — and then sends the live
    events of the session. The stream keeps its id and its counter: the
    resumed stream is the same logical stream. When the stream is still
    open, the new `GET` takes it over and the old connection gets no
    more events.
  * An id of a `POST` stream with the form `<stream>:<n>`. The `GET`
    replays only that `POST` stream and ends after its response. It
    does not carry the notifications of the session.

An id of a `GET` stream that the server does not know — an unknown,
forged or expired `g.` id, or an id of an older version, which held no
colon — starts a fresh stream and the server writes a warning. The
session stays valid. An id of a `POST` stream that the server does not
know (for example a forged value) gets `204 No Content`: there is
nothing to resume and the session stays valid.

### A client after a `retry:` hint

When a stream writes a `retry:` hint and ends, the callback of the
request was not cancelled. The client waits the number of milliseconds
of the hint, then sends a `GET` with the last event id that it saw in
`Last-Event-ID`. The resume must come within `sse_resume_window_ms` of
the end of the request.

The log of a stream stays for the option `sse_resume_window_ms`
(default 5 minutes) after the stream is over — after its response for
a `POST` stream, or after the close of the connection for a `GET`
stream. A resume of a `POST` stream after the window gets
`204 No Content` with no body
and no `retry:` field: the server logs this at `debug` level. The
client must not connect again
for that stream. A client that requires `text/event-stream` on each
`2xx` can report an error for the `204`: the error stops the reconnect
loop and the session stays valid. A resume of a `GET` stream after
the window is a resume with an id that the server does not know: it
starts a fresh stream, as the paragraph above describes. Set `0` to
drop the log of an ended
stream at once. With `0`, the server keeps no event that no `GET`
stream can take.

The events that the server sends when no `GET` stream is open go to
the newest `GET` stream that ended in the resume window, when one
exists: only a resume of that stream, with its `Last-Event-ID`,
replays them. When no `GET` stream ended in the window, the events
wait for the next `GET`: the server keeps them for
`sse_resume_window_ms` and the first `GET` — a fresh one, or one
with an id that the server does not know — replays them. The log caps
bound both holds.
The log of each stream has the caps `sse_event_log_size` (events) and
`sse_event_log_bytes` (bytes) and the logs of a session together have
the caps `sse_event_log_session_bytes` (bytes) and
`sse_event_log_max_streams` (number of logs). When the number of the
logs of a session goes over `sse_event_log_max_streams`, the log with
the oldest newest event goes first. The session keeps the logs of at
most 16 `GET` streams that ended. A cap that removes events of a
stream that a client is about to resume makes the client miss them: the
server writes a warning and the replay has a gap. An event is never
sent twice and an id of one stream never replays the events of another
stream. The warnings hold no text of a `Last-Event-ID` header and no
data of an event: these are client data.

When a session cap evicts the log of a stream that is not over, a
client that resumes this stream gets no replay of the evicted events and
the server writes the same warning. The log of a stream that is over can
also be evicted before the end of the window by one of the two session
caps: a resume then gets
`204 No Content` and the server logs this at `debug` level.

## The limits

| Option | Default | Limit | Answer over the limit |
|---|---|---|---|
| `max_sessions` | `10000` | the sessions of the server | `initialize` at the limit ends the idle session with the oldest activity and starts the new one; when no session is idle, it gets `429` with the error `-32000 "too many sessions"`. See the runtime options guide |
| `max_sessions_per_principal` | `100` | the sessions of one principal. A restore from a snapshot counts in this limit; a `DELETE` does not | `initialize` at the limit ends the idle session of the principal with the oldest activity and starts the new one; when no session is idle, it gets `429` with the error `-32000 "too many sessions"`. See the runtime options guide |
| `max_streams_per_session` | `8` | the open `GET` streams of one session. Only the live `GET` streams count: the `POST` response streams do not | the `GET` gets `200`: the session ends its oldest `GET` stream (a last `retry:` hint and its events stay for `sse_resume_window_ms`) and opens the new one. The limit event has `outcome` `replaced` |
| `max_subscriptions_per_session` | `1000` | the resource subscriptions of one session. A repeat subscribe of a URI that the session already holds is not a new subscription | the `POST` gets `200` with the error `-32000 "too many subscriptions"` with `data.limit` `max_subscriptions_per_session` |
| `max_body_bytes` | `1048576` | the bytes of the body of one request | the `POST` gets `413` with the error `-32600 "request body too large"` |

The value `nil` turns a limit off. `max_sessions_per_principal` covers
a server with an `authorization` block only: a server with no
authorization has no principal and `max_sessions` alone caps it.
`max_body_bytes` accepts no `nil`: a body that the server reads always
has a bound.

The router reads the body itself. Do not put `Plug.Parsers` before the
router in your pipeline. The router uses its own decoder, which
turns a JSON `null` into `nil`. A decoder of another library can give
another value for `null`. A parser before the router also skips the
limit `max_body_bytes`.

A body that does not arrive in full in the read time of the HTTP
server gets `408` with the error `-32600 "request body timeout"`.

The decoder refuses a JSON number whose text is longer than 100
characters. The server does this before it converts the number, so a
body with a very long integer costs no more CPU than any other body of
the same size. The answer is the same as for a body that is not JSON:
`400` with the error `-32700 "parse error"`. The text of a float is
counted after the decoder normalizes it (`1e5` becomes `1.0e5`).

## The status codes

| Status | When the server answers with it |
|---|---|
| `200` | a request with a valid result or error (this includes a message with a `notifications/*` method and an `id`, which gets `-32601`), an open stream and a `DELETE` that ended the session |
| `202` | a notification or a response of the client that the server accepted |
| `400` | a body that is not JSON, a body with a number of more than 100 characters, a batch array, a scalar JSON value, a missing session id, a session id that is not 1 to 128 bytes of visible ASCII, an `initialize` with a session id, an unsupported protocol version, a version that differs from the session, a session that waits for `initialize`, a malformed authorization header and a JSON-RPC refusal of a notification or a response |
| `401` | no valid credential on a protected server. The answer carries the `WWW-Authenticate` challenge |
| `403` | a host that the server does not allow, an origin that the server does not allow (an empty body) and a principal without the required scopes |
| `404` | an unknown session and a path that the endpoint does not serve |
| `405` | a method other than `GET`, `POST`, `DELETE` and `OPTIONS` |
| `406` | a missing `Accept` header, or a value without `application/json` and `text/event-stream` |
| `408` | a body that does not arrive in full in the read time of the HTTP server |
| `413` | a body over `max_body_bytes` |
| `415` | a `Content-Type` that is not JSON, or no `Content-Type` |
| `429` | `initialize` over a limit of the section above when no session is idle, or a `DELETE` that restores a session at the `max_sessions` limit or at the `max_sessions_per_principal` limit |
| `500` | an internal error of the server or of a store |
| `503` | the instance or its session process cannot answer (for example during a restart), or the read of the session failed. The caller can retry later |

A result that cannot be encoded gives a JSON-RPC error `-32603` with the
id of the request. The HTTP status stays `200` and an open stream ends
in a normal way.

Each refusal carries the JSON-RPC error envelope. The refusal of a
host and the refusal of an origin are the exception: their body is
empty. The envelope of a refused notification or response has no id.

## Production notes

Serve the endpoint behind TLS. The clients must reach the endpoint and
the metadata document at the URL of the option `resource_url`.

Bind the HTTP server to `127.0.0.1` for a local server:

```elixir
{Bandit, plug: MyApp.Router, ip: {127, 0, 0, 1}, port: 4000}
```

> **CAUTION:** A server on all the network interfaces accepts
> connections from your local network. A page in a browser can send
> requests to the server with DNS rebinding. The `allowed_origins`
> list and the section below give the protection against these requests.

A proxy between the client and the server must not buffer
`text/event-stream`. A proxy that buffers the stream holds the events and delays the answers.

A server that runs on many nodes needs three parts: sticky routing on
`Mcp-Session-Id`, a PubSub module that sends to every node for the
notifications and a shared store for the session snapshots and the
task records. The guide [Run many nodes](cluster.md)
gives the deployment model.

For a protected server, the path of the mount and the path of the
`resource_url` must agree. The metadata plug derives its well-known
URL from the `resource_url`.

## DNS rebinding

A page in a browser can attack a server that runs on the machine of the
person who reads the page. The page gives the browser a name of the
attacker. The DNS of that name answers first with the address of the
attacker and later with `127.0.0.1`. The browser then sends the
requests of the page to your server. Such a request carries a `Host`
header that names the domain of the attacker and no `Origin` header,
because the request does not cross origins: the list `allowed_origins`
does not stop it.

The option `allowed_hosts` stops it: it names the hosts that the
endpoint accepts in the `Host` header (default `:any`, every host). A
request with another host gets `403` with an empty body. The check runs
before the origin check. A stopped instance does not skip the host
check: it gets `503`. Set a list for a local server:

```elixir
{OzMcp,
 server: MyApp.McpServer,
 allowed_origins: [],
 allowed_hosts: ["localhost", "127.0.0.1", "[::1]"]}
```

The comparison runs in lower case on the host with no port: the client
sends `localhost:4000` in the `Host` header, the check compares
`localhost`. The host of an IPv6 request keeps its brackets, so the
list names `"[::1]"`.

## The session snapshot

With the default module `OzMcp.Session.Snapshot.None`, a stop of the
instance, or a crash of a session process, loses the session: the
client gets `404` and sends `initialize` again. A module that
implements the behaviour `OzMcp.Session.Snapshot` can keep the
persistent part of the sessions (the client capabilities, the log
level and the subscriptions). The next request of the client starts
the session again from its snapshot. The restore runs in the request
pipeline, after the checks of the session id and the protocol version
and the owner check of the session runs before the start. The streams
and the event log are not part of the snapshot. A restore at the
`max_sessions` limit or at the `max_sessions_per_principal` limit ends
the idle session with the oldest activity (see the runtime options
guide); a `DELETE` that restores a session at a full limit gets `429`
and ends no session. A restore counts in `max_sessions_per_principal`
and a `DELETE` does not. The guide about the runtime options gives the
option `session_snapshot`. The telemetry gives one event for each
attempt to restore, with the outcome of the attempt: the guide about
the telemetry lists the outcomes.

A message of the server (a notification, a request to the client)
never restores a session: a message for a session that the instance
does not know gives `{:error, :no_session}`. Only a request of the
client can start a session again.

The end of a session (a `DELETE`, the idle timer) marks its id in the
instance at once, before the delete of its snapshot runs: a request
with that id gets `404` and does not reach the module. A delete that
failed or that passed its time limit of 5 s keeps the mark for 60 s
and the snapshot can stay in the store. The mark is local to the node:
in a cluster with no sticky routing, another node can still read the
snapshot from the store until the delete ends. A store with its own
expiry (a time to live of its snapshots) closes this gap.

Each instance keeps a small cache of the session ids that the snapshot
module did not find. The option `session_restore_miss_ttl_ms` gives the
time of a miss (the default is `5000` ms; `0` turns the cache off).
While the cache holds a miss, the requests with that id get `404` and
do not reach the module. Two limits of the cache:

  * A cluster with no sticky routing: another node can write a
    snapshot while this node holds the miss of its id (a request can
    reach this node before `notifications/initialized` reaches the
    other node). For the time of the miss, this node answers `404`
    and the client starts a new session. Set `0` to turn the cache
    off for such a cluster.

  * A full cache holds no new miss: a flood of unknown ids reaches the
    module again. The cache lowers the cost of repeated ids; a rate
    limit of unknown ids stays the job of the host.

## Persistence

A module of the behaviour `OzMcp.Session.Snapshot` keeps the persistent
part of the sessions. The behaviour has three callbacks. Each one gets
the name of the instance as its first argument:

| Callback | When it runs |
|---|---|
| `save(instance, session_id, snapshot)` | after each persistent change of an initialized session that gives a snapshot the session does not hold yet. A change that gives the persistent part of the last write (for example `logging/setLevel` with the level the session has) calls nothing. The write runs later than the change: a writer process of the instance runs it and the session does not wait for the store. Two writes for one session never run at the same time; the writer keeps only the newest snapshot of a session. The session takes a write as done when it hands it over: a failed write waits for the next change that gives another snapshot. A stop of the node can lose the last change |
| `load(instance, session_id)` | in the request pipeline, in the process of the request, when the request names a session that the instance does not know, before the owner check of the snapshot. `load/2` has no time limit: a slow store holds the request until `load/2` returns. `{:ok, snapshot}` starts the session again, already initialized. `:not_found` gives `404`. The cache of the unknown ids holds a miss for `session_restore_miss_ttl_ms`: the requests of the same id while the miss is held do not reach `load/2`. A failure of `load/2` is never held |
| `delete(instance, session_id)` | in the writer of the instance, after the session ended and after the `DELETE` answer. The delete runs after a save of the same session that runs (a save that takes more than 3 s is stopped and the log gets one warning) and it has a time limit of 5 s. A save that the library stops can still reach the store if the store keeps a write after the stop of the process that sent it |

The restore happens only for a request of the client. A notification or
a request that the server sends never calls `load/2` and never starts a
session.

The example keeps the snapshots in an ETS table that the host
application owns (create it with `:ets.new/2` and the options `:public`
and `:named_table` at the start of the application). A production module
writes to a database:

```elixir
defmodule MyApp.Session.Snapshot do
  @behaviour OzMcp.Session.Snapshot

  @impl true
  def save(instance, session_id, snapshot) do
    :ets.insert(:my_app_snapshots, {{instance, session_id}, snapshot})
    :ok
  end

  @impl true
  def load(instance, session_id) do
    case :ets.lookup(:my_app_snapshots, {instance, session_id}) do
      [] -> :not_found
      [{_key, snapshot}] -> {:ok, snapshot}
    end
  end

  @impl true
  def delete(instance, session_id) do
    :ets.delete(:my_app_snapshots, {instance, session_id})
    :ok
  end
end
```

Give the module to the child:

```elixir
{OzMcp, server: MyApp.McpServer, session_snapshot: MyApp.Session.Snapshot}
```

A failure of `save/3` or `delete/2` writes a log and changes nothing
else: the session never waits for the writer. A failure of `load/2`
gives an unknown session. A session that crashed keeps its snapshot. A
crash of the writer loses the writes it holds: the next change of a
session saves again and no other child of the instance is touched. A
crash of the supervisor of the callbacks stops the write that runs under
it: that change is lost and the next change of the session saves again.
A delete that runs at the crash keeps its tombstone for 60 s at most
and the queued writes run again when the supervisor is back. A crash of
the writer also loses the queued deletes and stops the delete
that runs: a lost delete does not run again, its snapshot stays in the
store and the tombstone of its id refuses a restore for its hold time
(60 s) at most. A crash of the cache loses the tombstones and the
cached misses only: a queued delete in the writer still runs and a
restore of an id whose delete did not end can start the session again
until the delete runs. A store with its own expiry closes this gap.
Because a write runs later than the change or the end of the session, a
stop of the node can lose the last change and a queued delete: the
snapshot stays in the store. A delete that failed or that passed its
time limit
leaves the snapshot in the store too and the restore of its id stays
refused on this node for 60 s at most.

The library checks the map that `load/2` returns. The names of the
keys must be atoms and all six keys of the type
`OzMcp.Session.Snapshot.snapshot()` must be there. The values must have
the types of that type. The protocol version must be a version that
the instance supports. The library removes keys with other names. A map
of a wrong shape gives `404` for the request and one warning goes
into the log. A store that writes JSON must convert the map back to
that type before `load/2` returns the map.
