# Run many nodes

This guide gives the deployment model for a server that runs on more
than one node. It lists the state that stays on one node, the PubSub
module for broadcasts across the nodes, the routing rule, the failover
with a snapshot store and the limits of the model.

## When to use many nodes

One node holds about the number of sessions of `max_sessions` (10,000
by default). Use many nodes for one of these reasons:

* The server needs more sessions than one node can hold.
* The server needs more CPU than one machine gives.
* The server needs a rolling deploy with no stop.

A cluster adds work: sticky routing, a shared store for the session
snapshots and for the task records and a revocation that runs on each
node. Use one node until a reason above is true.

## What is local to a node

Almost all the state of an instance is local to the node that runs it:

| Item | Where it lives | Effect in a cluster |
|---|---|---|
| Session process, `Names` Registry | the node that started the session | A request for a session on another node gets `404`, unless the instance restores the session from a snapshot store (see below) |
| `max_sessions`, `max_sessions_per_principal` | the `Names` and `Principals` Registries | Each node counts its own sessions. The real limit for a principal is `nodes × max` |
| `terminate_principal/2`, `list_principal/2` | the `Principals` Registry | They act on the local node only. A revocation must run on each node |
| Event log for `Last-Event-ID` | the session process | A resume works only on the node of the session |
| Task records (`OzMcp.Tasks.EtsStore`) | ETS of the node | `tasks/get` on another node finds nothing. Use a shared `:task_store` |
| PubSub broadcasts | `Registry` on the local node, or `:pg` on the cluster | See the next section |

The hint `notifications/tasks/status` from a client is local to the
node that receives it: it reaches the waiters of that node only. The
poll of the waiter is the source of truth, so a hint that another node
receives costs one poll interval. A request that the server sends as a
task of the client works across nodes with no shared store.

## Broadcasts across nodes

The default module, `OzMcp.PubSub.Registry`, keeps the subscribers in a
`Registry` of the local node. A notification therefore reaches the
sessions of the node that sends it only.

Set `pubsub: OzMcp.PubSub.PG` to send a broadcast to every connected
node that runs the same instance:

```elixir
children = [
  {OzMcp,
   server: MyApp.McpServer,
   pubsub: OzMcp.PubSub.PG,
   session_snapshot: MyApp.SessionStore,
   task_store: MyApp.TaskStore},
  {Bandit, plug: MyApp.Router, port: 4000}
]
```

The rules of `OzMcp.PubSub.PG`:

* The instance has the same name on every node.
* The nodes are connected with Erlang distribution. OzMcp does not
  connect them. The host does this work, for example with `libcluster`
  or `dns_cluster`.
* The delivery is "at most once". There is no acknowledgement and no
  order between two senders.
* A node that has just joined can miss a broadcast for a short time,
  until `:pg` synchronises its groups.
* A node that is cut from the cluster gets no broadcast. The groups are
  synchronised again when the nodes connect.

A feature that must not lose an event needs a client that reads the
state again, for example a `resources/read` after a
`notifications/resources/updated`.

## Routing with a session id

All the requests with the same `Mcp-Session-Id` must reach the node
that holds the session. A request with no header (`initialize`) can go
to any node. That node makes the id and the id does not name the node.
The load balancer must therefore learn the id from the response of
`initialize`.

A hash of the header is not sufficient: it selects a node with no
relation to the node that made the id and the client gets `404`.

The load balancer keeps a table of the session ids and the node that
answered `initialize` with each id. These examples show the rule.
Check them against the documents of each product before you use them.

```text
# HAProxy
backend mcp
  stick-table type string len 128 size 100k expire 1h
  stick on req.hdr(mcp-session-id)
  stick store-response res.hdr(mcp-session-id)

# NGINX Plus (the open source version has no `sticky learn`)
upstream mcp {
  zone mcp 64k;
  sticky learn create=$upstream_http_mcp_session_id
               lookup=$http_mcp_session_id
               zone=mcp_sessions:10m timeout=1h;
}
```

The `expire` or `timeout` value must not be shorter than
`session_timeout_ms`. A client that comes back after a longer time gets a
new session and the table entry of the old session is gone.

A `GET` stream and the `POST` of the same session must reach the same
node: the stream is a process of that node.

## Failover with a snapshot store

When a node stops, its sessions are lost unless the instance has a
`session_snapshot:` module. With a store, any node can restore a
session on the next request.

The limits of this failover:

* Two nodes can restore the same id at the same time if the routing is
  not sticky. The tombstone of an ended session and the cache of a
  missing snapshot are local to a node.
* The event log is not part of the snapshot. A resume with
  `Last-Event-ID` after a failover has no events to replay.
* The open requests to the client are lost.
* A hash rule with a snapshot store is not a replacement for a learned
  route. The save is asynchronous, so the first request on another node
  can miss the snapshot. The miss cache then holds that id for
  `session_restore_miss_ttl_ms` and the session of the first node stays
  open.

## Limits and revocation

Each node counts its own sessions. The limit `max_sessions` applies to
one node and the limit `max_sessions_per_principal` applies to one
node. A principal can therefore hold up to `nodes × max` sessions.

A revocation must run on each node. The calls to the local node only
are not sufficient:

```elixir
defmodule MyApp.Revocation do
  def revoke(principal_key) do
    for node <- [node() | Node.list()] do
      :erpc.call(node, OzMcp.Sessions, :terminate_principal, [
        MyApp.McpServer,
        principal_key
      ])
    end
  end
end
```

Refuse the token of the principal at the same time. Step 1 of the guide
about authorization stops a new session and a new request. This loop
ends the sessions that exist on the nodes that are connected.

## Rolling deploy

To deploy a new version, drain one node at a time:

1. Stop the node from the load balancer. It gets no new request.
2. Wait for `session_timeout_ms`, so the open sessions end in the normal
   way, or stop the node and let the clients restore their sessions
   from the snapshot store.
3. Start the new version on the node.
4. Put the node back in the load balancer.

The session ids of the old node stay in the routing table until the
`expire` or `timeout` of the table. The clients that had a session on
that node get a new session when the table entry is gone.

## Sizing and the benchmark

The folder `bench/` holds the scenarios that measure one node. The
guide `bench/README.md` gives the procedure and the columns of the
table. A run on the machine of the project at Git `5dd40df` gave these
numbers as a reference:

| Scenario | req/s | p50 (µs) | p95 (µs) | p99 (µs) |
|---|---|---|---|---|
| `ping_10k` | 5752 | 153 | 261 | 340 |
| `stream_1k` | 2035 | 419 | 636 | 854 |
| `sessions_1k` | 4105 | 230 | 343 | 412 |
| `principal_1k` | 10033 | 88 | 157 | 193 |

These numbers depend on the CPU, the count of schedulers and the
versions of Elixir and OTP. A result from another machine is not
comparable. Measure the nodes of the cluster with the same scenario
and set `max_sessions` from the result.

## What OzMcp does not do

OzMcp does not give these parts of a cluster:

* A session id that is unique in the cluster.
* A session id that names its node, so that a load balancer can route
  with no learned table.
* A limit of sessions for a principal in the cluster.
* A revocation that reaches all the nodes.
* A shared task store. The host writes a module for `:task_store`.
* Node discovery and node connection. The host does this work.
* A relay process on each node. A broadcast sends one message for each
  remote session, not one message for each node.
