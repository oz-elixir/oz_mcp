# Protocol conformance

This matrix describes OzMcp 0.9.1 against the Model Context Protocol
specification, revision **2025-11-25**. It is the only revision that the
server supports.

Legend: ✅ implemented · 🟡 partially implemented · ❌ not implemented

## Checked by

The CI checks the server from the outside on each build:

- The official conformance tool, `@modelcontextprotocol/conformance`
  0.1.16 (`server` scenarios). One scenario is expected to fail:
  `server-sse-multiple-streams`. It sends the header
  `MCP-Protocol-Version: 2025-03-26` and the server answers `400`, as
  the transport specification requires for a version that the server
  does not support. The list of expected failures is in
  `test/conformance/expected_failures.yml`.
- The official TypeScript SDK client, `@modelcontextprotocol/sdk`
  1.32.2, over HTTP and stdio (`mix test.sdk`).

## Base protocol

- ✅ JSON-RPC 2.0 requests, notifications and responses, with a check of the envelope
- ✅ Request ids: strings and integers of any size; `null`, float, boolean and object ids are refused with `-32600`
- ✅ A request id is unique while its request runs; a duplicate gets `-32600`
- ✅ Batches refused (`-32600 "batching is not supported"`), on HTTP and stdio
- ✅ Parse errors: text that is not JSON, invalid UTF-8, a lone surrogate, text after the object, a number over 100 characters, `1e400` all give `-32700`
- ✅ `params` must be an object; `null` counts as absent
- ✅ A method that exists only as a notification is refused as a request (`-32601`); an unknown notification is ignored
- 🟡 `_meta`: the type is checked on a message of the client (an object, a string or integer `progressToken`); the key format and the reserved prefixes are checked on what the server declares, not on what the client sends
- ✅ Standard error codes, plus `-32002` (resource not found) and `-32042` (URL elicitation required)
- ✅ Every response carries its `id`, also when the callback raises or returns a wrong shape (`-32603`)
- ✅ Icons, `title`, `description` and `websiteUrl` where the specification puts them
- ✅ JSON Schema 2020-12 by default

## Lifecycle

See [Declare a server](guides/servers/declare_a_server.md) and
[Runtime options](guides/runtime/runtime_options.md).

- ✅ `initialize`: version negotiation (an unknown version gets `2025-11-25`), `clientInfo` and `capabilities` checked, `instructions`
- ✅ A second `initialize` is refused on both transports
- ✅ `notifications/initialized`; a second one is accepted and ignored
- ✅ Requests before the initialization are refused; `ping` is allowed
- ✅ Initialization timeout, `DELETE`
- ✅ Idle timeout with one rule: a stream, a request, a request to the client or a tracked task holds the session; it expires `session_timeout_ms` after the last one ends
- ✅ Capability gating: a method of a capability that the server does not declare gives `-32601`
- ✅ `ping` in both directions
- ✅ A request of the server role sent by the client gives `-32601`
- ❌ Protocol revisions other than 2025-11-25 (by design)

## Transport: stdio

See [stdio transport](guides/runtime/stdio_transport.md).

- ✅ Newline-delimited JSON, logs on stderr only
- ✅ Concurrent requests, drain at the end of stdin, bounded output queue
- ✅ The same outcome as HTTP for every message, except a malformed answer of the client, which gets no line on stdio
- ✅ Every request gets one line, also on a crash
- ✅ An answer of the client gets no line, valid or malformed, with an id or with none

## Transport: Streamable HTTP

See [HTTP transport](guides/runtime/http_transport.md).

- ✅ `POST`, `GET`, `DELETE`, `OPTIONS` on one endpoint, `405` with `Allow`
- ✅ `Accept` and `Content-Type` checks
- ✅ JSON and SSE answers, lazy upgrade to SSE, priming event
- ✅ `202` for notifications and for answers of the client
- ✅ `Mcp-Session-Id`: visible ASCII, `400` when missing, `404` when unknown or foreign
- ✅ `MCP-Protocol-Version`: `400` for an unsupported value
- ✅ Origin check (`403`), Host allow-list (DNS rebinding protection)
- ✅ Limits: sessions, streams, subscriptions, body, numbers, tokens
- ✅ Session limit with reclaim of the oldest idle session; `429` only when no session is idle
- ✅ `GET` SSE: `retry:`, heartbeats, poll close, several streams per session
- ✅ Resumability with `Last-Event-ID`
- 🟡 The resume of an unknown or ended `POST` stream gets `204` (on purpose, to stop reconnect loops)
- ✅ Server-initiated close of a `POST` stream with `retry:` (SEP-1699); the callback goes on
- ✅ A disconnect is not a cancel, on Bandit and on Cowboy

## Authorization (resource server)

See [Authorization](guides/runtime/authorization.md).

- ✅ Protected Resource Metadata (RFC 9728), `WWW-Authenticate` with `resource_metadata` and `scope`
- ✅ Bearer token in the header only, strict parsing, size limit, checked before the body is read
- ✅ Audience check (RFC 8707), fails closed
- ✅ Step-up with `insufficient_scope`
- ✅ Pluggable `authenticate/2` and `authorize/3`, both fail closed
- ✅ `required_scopes` per entity, filtered lists
- ✅ Session bound to `{issuer, subject}`; a foreign session gets `404`
- ✅ Local revocation, token expiry during a stream
- ✅ No authorization on stdio, as the specification expects
- ❌ Authorization server, dynamic client registration (out of scope)

## Tools

See [Tools](guides/entities/tools.md).

- ✅ `tools/list` with pagination; a cursor of a wrong type, an unknown cursor and an empty cursor give `-32602`
- ✅ `tools/call`; an unknown tool gives `-32602`; input errors are tool errors (`isError: true`)
- ✅ `inputSchema` check with defaults; `outputSchema` and `structuredContent` checked
- ✅ `title`, `annotations`, `icons`, `_meta`, `execution.taskSupport`
- ❌ `notifications/tools/list_changed` (by design: the list is fixed at boot)
- ✅ All content types, resource links, embedded resources
- ✅ Tool name format (SEP-986)

## Resources

See [Resources](guides/entities/resources.md) and
[Templates](guides/entities/templates.md).

- ✅ `resources/list`, `resources/templates/list`, `resources/read`; an unknown URI gives `-32002`
- ✅ `resources/subscribe` (an unknown resource gives `-32002`), `resources/unsubscribe`, `notifications/resources/updated`
- ❌ `notifications/resources/list_changed` (by design: the lists are fixed at boot)
- ✅ URI templates, RFC 6570 levels 1 to 3
- 🟡 RFC 6570 level 4 modifiers: refused at compile time (by design: never implemented)
- ✅ Annotations, `size`, text and binary contents

## Prompts

See [Prompts](guides/entities/prompts.md).

- ✅ `prompts/list`, `prompts/get`
- ❌ `notifications/prompts/list_changed` (by design: the list is fixed at boot)
- ✅ Argument checks: a missing required argument, a value that is not a string and an unknown argument give `-32602`
- ✅ All content types in messages

## Utilities

See [Completions](guides/entities/completions.md) and
[Notifications](guides/runtime/notifications.md).

- ✅ `completion/complete` with prompt and resource references and `context.arguments`
- ✅ `logging/setLevel` (an unknown level gives `-32602`), `notifications/message`, level filter, log rate limit per session
- ✅ Pagination with opaque cursors
- ✅ Incoming `notifications/cancelled` with a two-step stop; an unknown id is ignored
- ✅ `notifications/progress`, increasing values only

## Client features (requests of the server)

See [Client requests](guides/runtime/client_requests.md).

- ✅ `sampling/createMessage` with `tools`, `toolChoice`, `includeContext`
- ✅ `elicitation/create` in form mode and in URL mode, with `notifications/elicitation/complete`
- ✅ `roots/list`, `notifications/roots/list_changed`
- ✅ Capability check before sending; timeouts per method; cancel on timeout
- ✅ An answer of the client with a result and an error, a result that is not an object, or a malformed error is refused
- 🟡 A request of the server tied to a client request that has no open stream falls back to the `GET` stream (kept on purpose)

## Tasks (experimental)

See [Tasks](guides/runtime/tasks.md).

- ✅ `tasks` capability and `taskSupport` gating
- ✅ Task metadata check: `ttl` type and ceiling
- ✅ `tasks/get`, `tasks/list`, `tasks/result`, `tasks/cancel`; an unknown `taskId` gives `-32602`
- ✅ A running task holds its session with `tasks_follow_session`
- ✅ A task process that dies with no `untrack_task` frees its session
- ✅ Owner isolation and scope checks
- ✅ `notifications/tasks/status`, `ttl`, `pollInterval`, timestamps, `statusMessage`
- ✅ `input_required` with held requests; related-task `_meta`
- ✅ Limits per owner
- ✅ Server as requestor (option `client_tasks`, off by default)

## Many nodes (outside the specification)

See [Cluster](guides/runtime/cluster.md).

- ✅ Broadcast across nodes with `OzMcp.PubSub.PG`, at most once
- ✅ Sticky routing and failover guide
- ✅ A request that arrives right after a session crash restores the session from the snapshot
- 🟡 Failover through a snapshot store: the event log and the open requests to the client are lost (documented)
- ❌ Limits, revocation and the task store across the cluster (out of scope)
