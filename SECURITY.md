# Security policy

## Supported versions

OzMcp is experimental and has not reached 1.0. Only the latest released
version gets security fixes. A fix is not backported to an older 0.x
version.

| Version | Supported |
|---|---|
| Latest 0.x release | Yes |
| Older 0.x releases | No |

## Report a vulnerability

Do **not** open a public issue, a pull request or a discussion for a
security problem.

Report it in private with GitHub: open the **Security** tab of the
repository, then **Report a vulnerability**. The report stays private
between you and the maintainer until a fix is published.

Give, when you can:

* the version of OzMcp (or the commit), of Elixir and of OTP;
* the HTTP server (Bandit or Cowboy) or the stdio transport;
* the part of the server that is affected (for example the `POST`
  route, the `GET` stream, the authorization gate, the session limits);
* the steps or a small script that shows the problem and what an
  attacker gains (a bypass, data of another session, a crash, a denial
  of service);
* whether the problem needs an authenticated principal, or works on an
  open server.

Do not put real tokens, credentials or data of other people in the
report.

## What happens next

This project has one maintainer, so the times below are goals, not
promises.

1. The report is acknowledged within 7 days.
2. The maintainer confirms the problem, or explains why it is not one,
   within 30 days.
3. A confirmed problem is fixed in a new release. The fix is announced
   in a GitHub security advisory, with credit to the reporter unless they
   ask not to be named.

Please keep the problem private until the advisory is published, or
until 90 days have passed since the report, whichever comes first.

## Scope

In scope: the code of this repository, that is the transports (HTTP and
stdio), the validation of messages, the sessions and their isolation,
the authorization gate (`OzMcp.Auth`), the tasks and the limits of the
runtime.

Out of scope:

* the code of an application built with OzMcp: its tools, resources,
  prompts, its `authenticate/2` and `authorize/3` callbacks and the
  token verification it does;
* the HTTP server and the proxy in front of it and their configuration;
* problems of the MCP specification itself (report them to the
  [MCP project](https://github.com/modelcontextprotocol/modelcontextprotocol));
* a denial of service that needs more traffic than a rate limit in front
  of the server would let through.

## Deploy with care

OzMcp is a library: the security of a server depends on how it is
deployed. Before you expose a server on a network:

* Use an `authorization` block for any server that is not on the local
  machine. An open server serves anyone who can reach it.
* Put a rate limit (in the proxy or in the host application) in front of
  the MCP endpoint. A session holds a slot of `max_sessions` until it is
  deleted or until its timeout (`session_init_timeout_ms` before
  initialization, `session_timeout_ms` after), so a burst of
  `initialize` requests can fill the pool.
* Set `allowed_origins` to the origins of the browser clients you trust
  and `allowed_hosts` to the host names of the server (the default
  `:any` does not check the `Host` header).
* Keep `max_body_bytes`, `max_sessions`, `max_sessions_per_principal`
  and the other limits at values that fit your machine. The runtime
  options guide lists them.
* Do not log the content of requests in production: tokens, arguments
  and results can hold data of your users.
