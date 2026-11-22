defmodule OzMcp do
  @moduledoc """
  OzMcp is an Elixir framework to write MCP servers. It supports the
  revision `2025-11-25` of the Model Context Protocol only. The
  [README](README.md), the main page of these docs, lists the guides.

  ## Main modules

  * `OzMcp.Config.Server` declares a server: its information, its
    capabilities and its tools, resources, templates and prompts.
  * `OzMcp.Config.Tool`, `OzMcp.Config.Resource`,
    `OzMcp.Config.Template` and `OzMcp.Config.Prompt` declare the
    entities of a server.
  * `OzMcp` (the child spec `{OzMcp, opts}`) starts a server in the
    supervision tree of the host application.
  * `OzMcp.Router` is the plug of the Streamable HTTP transport.
  * `Mix.Tasks.OzMcp.Stdio` runs a server on the stdio transport.
  * `OzMcp.Notify`, `OzMcp.Client` and `OzMcp.Tasks.Context` are the
    API of the callbacks.

  ## Options

  The child spec `{OzMcp, opts}` takes the option `:server` (the server
  module, required), the option `:name` (the name of the instance, the
  server module by default) and the other options of the table of the
  guide about the runtime options. Each option has its default, its
  unit and its check at boot there.

  ## Restart rules

  An instance is a tree of three levels. `Core` owns the three
  Registries and the owner of the task table. `PubSub` holds the
  processes of the `:pubsub` module (only if the module has them).
  `Workers` holds the supervisor of the callbacks, the supervisor of the
  sessions, the supervisor of the tasks, the reaper and the two
  processes of the snapshot.

  * A crash of one Worker restarts that Worker only. A crash of the
    reaper loses nothing when the store has `active/1`: the new reaper
    monitors the running tasks again. A crash of the supervisor of the
    sessions ends the sessions and keeps the task records. A crash of
    the supervisor of the tasks or of the supervisor of the callbacks
    makes the tasks that it runs `failed`. The task records stay. A
    crash of the supervisor of the callbacks also stops the snapshot
    writes that run: a stopped delete keeps its tombstone and the
    queued writes run again when the supervisor is back.
  * A crash of a process of `PubSub` restarts `PubSub` and `Workers`:
    all the sessions and all the running tasks stop. The task records stay.
  * A crash of a process of `Core` restarts `Core`, `PubSub` and
    `Workers`: all the sessions and all the task records of the default
    store are lost.
  * A crash of a session or of a task process restarts no other
    process. The other instances keep their pids. A crash loop of one
    Worker restarts `Workers`: all the sessions and all the running
    tasks stop and the task records stay. A crash loop of `Workers`,
    `Core` or `PubSub` restarts the instance and the other instances
    keep their processes and their sessions.
  * A crash loop above that restarts the host application supervisor.

  A session is a process. A crash of the session process loses the
  session, unless the snapshot module keeps it (the option
  `:session_snapshot`): the next request of the client starts the session
  again from its snapshot and the client continues. With the default
  module, the clients get `404` for their session ids and send
  `initialize` again, which the MCP transport rules ask them to do for an
  unknown session.

  The transports see the loss and act on it:

  * A `GET` stream and a resumer of a `POST` stream, monitors the
    session process that owns it. When that process stops, the stream
    ends with a `retry:` hint and the client connects again with its
    `Last-Event-ID` (see `OzMcp.Router`).
  * The stdio transport monitors its session process. When it stops, the
    transport writes an error on stderr and stops with
    `{:shutdown, :session_lost}`. The Mix task then exits with code 1
    (see `OzMcp.Transport.Stdio`).

  A crash of the process of a task keeps the task record (a separate
  process owns the tables): the reaper marks the task as `failed` and the
  client receives the status notification. A crash of that table owner
  deletes all task records of the server.

  ## End the sessions of a principal

  When the application revokes the access of a principal, do two things in
  this order:

    1. Refuse the token of the principal in `c:OzMcp.Auth.authenticate/2`.
    2. Call `OzMcp.Sessions.terminate_principal/2` with the principal or
       its key.

  Step 1 stops a new session and a new request. Step 2 ends the sessions
  that exist. If the application does step 2 only, the client can start a
  new session with the old token. The result `{:ok, []}` can also mean that
  a snapshot module does not keep the principal key of its sessions.

  Step 2 works with the default PubSub module and with a custom one:
  `terminate_principal/2` reads the sessions of the instance, not the
  subscribers of a topic. It ends the sessions of the local node only.

  The key is `{issuer, subject}`. The issuer is a string or `nil`. The
  subject is a non-empty string. A key with another shape raises
  `FunctionClauseError`. The functions compare the key as a value: an atom
  such as `:_` is not a wildcard.
  """

  @doc """
  The child spec of one MCP server instance.

      children = [
        {OzMcp, server: MyApp.McpServer, allowed_origins: ["http://localhost:4000"]},
        {Bandit, plug: MyApp.Router, port: 4000}
      ]
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(opts), to: OzMcp.Instance
end
