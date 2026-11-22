# stdio transport

This guide describes the stdio transport. A local client starts the
server as a subprocess and the two processes speak over stdin and
stdout. The guide about the runtime options gives the options of the
runtime config. The guide about the HTTP transport describes the
transport for a server on a network.

## When to use stdio

Use the stdio transport when a local client starts the server as a
subprocess of its own process. The client writes each JSON-RPC message
as one line to the stdin of the subprocess. The server writes each
answer as one line to the stdout of the subprocess. The MCP clients use
this transport for a local server, for example a server that reads the
files of a project.

The client owns the process of the server. There is no network, no
origin check and no credential. The client sends no `Origin` header,
so the runtime config needs no `allowed_origins` list for the `:stdio`
transport. The key is optional and the runtime checks it when you give
it.

The stdio transport decodes the messages in the same way as the HTTP
transport: a JSON `null` in a message is `nil`.

## Run the server with the Mix task

The Mix task runs one server on stdin and stdout:

```shell
mix oz_mcp.stdio MyApp.McpServer
```

The task loads the configuration of your application. It starts the
application `:oz_mcp` and it runs the transport with the server
module. Without `--start-app`, the host application does not start: a
callback cannot use the processes of the host, for example a repository
or a cache.

The task takes the options of this table:

| Option | Value | Job |
|---|---|---|
| `--start-app` | flag | starts the host application (`app.start`), not only its configuration |
| `--instance NAME` | a name | the name of the instance to start or join. The default is the server module |
| `--log-level LEVEL` | a level of the `Logger` | sets the level of the log. The line of each request is at level `:debug`: give `debug` to see it |
| `--drain-timeout MS` | milliseconds, `0` allowed | how long the server waits for the requests in flight after the end of stdin. The default is `1000` |
| `--max-queue N` | messages, positive integer | how many messages may wait for stdout before the transport stops with an error. The default is `10000` |

With `--start-app`, the host application starts and the transport
joins the runtime that the application runs. A host that starts a web
server also opens its HTTP port. Use this flag when the callbacks of
the server need the processes of the host.

## The client configuration

The client starts the command as a subprocess. The entry of the
configuration gives the command, the arguments, the folder and the
environment:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "mix",
      "args": ["oz_mcp.stdio", "MyApp.McpServer"],
      "cwd": "/path/to/my_app",
      "env": { "MIX_ENV": "prod" }
    }
  }
}
```

The messages that Mix prints before the task starts (for example
"Compiling 4 files") go to stdout, not to stderr: Mix compiles the
project before it finds the task. A client that starts the command
after a change of the source can read these messages as its first
line. Use the form with `sh -c` below, which sends these messages to
stderr:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "sh",
      "args": ["-c", "mix compile >&2 && exec mix oz_mcp.stdio MyApp.McpServer --start-app"],
      "cwd": "/path/to/my_app",
      "env": { "MIX_ENV": "prod" }
    }
  }
}
```

## stdout carries the messages only

stdout carries the JSON-RPC messages of the server, one message per
line and nothing else. One log line or one stray print on stdout
breaks the protocol of the client. The logs go to stderr: the task
moves the handler of the `Logger` and the group leader of the process
tree to stderr before it starts the transport
(`OzMcp.Transport.Stdio.Console`). A stray print of a callback goes to
stderr too.

While the transport runs, the server writes one line for each request.
A failure after the run of the request does not take the answer away:
the server still writes one line. A response that cannot be encoded
gives the error line `-32603` with the id of the request. A message
that gets no answer (a notification, or an answer of the client) gets
no line.

A line that holds a JSON number whose text is longer than 100 characters
is a parse error: the server writes `-32700 "parse error"` with no `id`
and the transport reads the next line. The check runs before the
conversion, so the line costs no more CPU than any other line of the
same size.

## The messages of a connection

The transport validates each line in the order of the lines. A line
that is not JSON gets `-32700` with no `id`, a JSON array or a JSON
scalar gets `-32600`, an empty line is ignored and a line that ends
with `\r\n` is accepted.

The session of the connection comes into existence with the first
`initialize`. Before it, `ping` is answered and any other request
gets `-32600 "waiting session initialization"`. The session opens when
the client sends `notifications/initialized`; requests stay refused
until then. A second `initialize` gets `-32600 "session already
initialized"`: one connection holds one session.

The messages of one request keep their order: the response of the
request is the last line of its own messages. The messages that the
callback sends while it runs and the messages that no request owns
(the change notifications, for example), all reach stdout through the
one writer, so the lines never mix.

A `notifications/cancelled` is best effort. The transport reads the
next line as soon as it started the process of a request. A cancel
that the client writes in the same write as its request, or just after
it, can arrive before the request is registered. The cancel is then
ignored and the request runs to its end. A client that must cancel at
once waits for the first message of the request (a
`notifications/progress` or a request of the server) before it sends
the cancel.

There is no limit on the size of one line and no limit on the number
of requests in flight: the client owns the process of the server and
can only exhaust itself. A byte-order mark at the start of stdin makes
the first line a parse error: the client must not send one.

## Authorization on stdio

A server with an `authorization` block runs open on stdio. The client
owns the process of the server, so there is no principal, no scope
check and no filter on the lists. The runtime writes one log line at
the boot that says the block is not used. The runtime option
`resource_url` is not required and not checked for the `:stdio`
transport. The guide about authorization gives the details of the
block.

## The options of the server

The Mix task gives no option for one server: it starts the runtime with
the default options. To give the options of a server, use `--start-app`
with a host application that starts `OzMcp` itself, with
`transport: :stdio` and the options of the server:

```elixir
defmodule MyApp.StdioApplication do
  use Application

  # Started with: mix oz_mcp.stdio MyApp.McpServer --start-app
  @impl true
  def start(_type, _args) do
    children = [
      {OzMcp,
       server: MyApp.McpServer,
       transport: :stdio,
       request_timeout_ms: 30_000}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.StdioSupervisor)
  end
end
```

Set this module as the application module of the project in `mix.exs`
(`mod:` in the `application` key) when the project serves the stdio
transport only. The task starts the application and the transport
joins the runtime that runs the server. The table of the options of a
server entry is in the guide about the runtime options. The runtime
checks each value at boot.

## Run the transport from your own code

A release runs without Mix. Call the function
`OzMcp.Transport.Stdio.run/2` from the entry point of the release. The
function blocks until the connection ends:

```elixir
io = OzMcp.Transport.Stdio.Console.open()

:ok = OzMcp.Transport.Stdio.run(MyApp.McpServer, read: io.read, write: io.write)
```

Call `OzMcp.Transport.Stdio.Console.open/0` first, in the process that
starts the transport. The function sets the character set of the
standard devices to UTF-8, moves the logs to stderr and returns the
`:read` and `:write` functions.

`run/2` takes the options of this table:

| Option | Job |
|---|---|
| `:read`, `:write` | the functions that read stdin and write stdout. Required |
| `:instance` | the name of the instance to join, or to start. The default is the server module |
| `:server_opts` | the opts of the server for the runtime. The default is `%{}` |
| `:drain_timeout_ms` | how long the transport waits for the requests in flight after the end of stdin. The default is `1000` |
| `:max_queue` | how many messages may wait for stdout before the transport stops with an error. The default is `10000` |

When the runtime does not run, `run/2` starts one with
`transport: :stdio`, the one server and its `:server_opts`. This is a
second way to give options to the server. When an instance with the
name `:instance` runs, the transport joins it. The join does not check
the server module of the running instance.

The result of `run/2` is `:ok` after a normal end of the connection
(the end of stdin, or the runtime ended the session), or
`{:error, reason}` for a failure: a failed write to stdout, a stdout
reader that is too slow (`{:error, {:shutdown, {:output_overflow,
max}}}`), a failed reader of stdin, or a session that ended with
`session_init_timeout_ms` (`{:error, {:shutdown, :init_timeout}}`).
The function
`OzMcp.Transport.Stdio.start_link/1` starts the transport process
alone, for a test or an entry of its own.

## The reuse of a request id

The spec says that a request id must not be used again in the same
session. The client has this duty. The server refuses an id that is
**running** (`-32600`, `"request id already in use"`). It does not
remember an id after the answer. A client that sends the same id again
after the answer gets a normal answer.

## The end of the session

The session of a stdio connection has no id on the wire. The first
`initialize` creates it and the end of the input ends it. A second
`initialize` on the same connection gets the error `-32600`.

The end of stdin starts a drain:

  * The transport waits for the requests in flight, up to the drain
    time (`1000` ms by default, `0` ends at once).
  * After the drain time, the transport ends the session and writes the
    messages of its queue and the Mix task exits with code 0.
  * A request that still runs at the end of the drain time is
    cancelled and the answer line of a cancelled request is not
    guaranteed.
  * The runtime can also end the session and the transport stops
    normally, as after the end of stdin. One exception: when the session
    ends because the client sent no `notifications/initialized` within
    the option `session_init_timeout_ms`, the transport writes one error
    line on stderr and stops and the Mix task exits with code 1. The
    message names the option `session_init_timeout_ms`.

A client must read the answers that it needs before it closes stdin, or
it must accept the drain time.

Other ends of the transport:

  * A write to stdout that fails stops the transport with an error: the
    reader of the client is gone and no answer can reach it.
  * A client that does not read stdout makes the output queue of the
    transport grow. When more than `:max_queue` messages wait, the
    transport stops with an error: a very bursty server with a slow
    client needs a higher `:max_queue`.
  * A failure of the read of stdin stops the transport with an error.
    This covers a `read` function that raises and a `read` function
    that returns `{:error, reason}`: a read error is not the end of the
    input and no line will arrive, so the client waits for ever.

A crash of the session process is a special case. The transport
monitors the session process. When it stops, the session is lost: the
transport writes an error on stderr and stops. The Mix task exits with
code 1. The message on stderr names the case. The client starts the
server again.

The option `session_snapshot` of the runtime config keeps the persistent
part of the sessions, but a stdio connection does not use it: the
connection ends with its session.
