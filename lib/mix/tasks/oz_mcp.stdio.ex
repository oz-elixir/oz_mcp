defmodule Mix.Tasks.OzMcp.Stdio do
  @shortdoc "Runs an MCP server on stdin and stdout"

  @moduledoc """
  Runs an MCP server on the stdio transport, for a local client that
  starts this command as a subprocess.

      $ mix oz_mcp.stdio MyApp.McpServer

  Each line of stdin carries one JSON-RPC message of the client; each
  message the server sends is written as one line of UTF-8 text on
  stdout. From the start of the task, logs, the messages of Mix and
  stray prints of the callbacks go to stderr, so stdout carries
  JSON-RPC messages only. The command does not start the host
  application; give `--start-app` to start it and use the runtime that
  already runs it.

  The options, the client configuration and the notes about the
  messages that Mix prints before the task starts are in the guide
  [stdio transport](guides/runtime/stdio_transport.md).
  """

  use Mix.Task

  @switches [
    start_app: :boolean,
    instance: :string,
    log_level: :string,
    drain_timeout: :integer,
    max_queue: :integer
  ]
  @levels ~w(debug info notice warning error critical alert emergency)

  @impl Mix.Task
  def run(args) do
    {name, opts} = parse_args!(args)

    # First: from here on, nothing that Mix or a callback prints can
    # reach stdout.
    #
    io = OzMcp.Transport.Stdio.Console.open()

    Mix.Task.run("app.config")
    server = fetch_server!(name)
    if opts[:start_app], do: Mix.Task.run("app.start")
    {:ok, _apps} = Application.ensure_all_started(:oz_mcp)

    set_log_level(opts[:log_level])

    transport_opts =
      [read: io.read, write: io.write] ++
        if(opts[:drain_timeout], do: [drain_timeout_ms: opts[:drain_timeout]], else: []) ++
        if(opts[:max_queue], do: [max_queue: opts[:max_queue]], else: []) ++
        if(opts[:instance], do: [instance: Module.concat([opts[:instance]])], else: [])

    case OzMcp.Transport.Stdio.run(server, transport_opts) do
      :ok -> :ok
      {:error, reason} -> Mix.raise(stop_message(reason))
    end
  end

  # Public for the tests: it runs before the console is changed.
  #
  @doc false
  def parse_args!(args) do
    {opts, argv} = OptionParser.parse!(args, strict: @switches)

    case opts[:drain_timeout] do
      nil -> :ok
      ms when is_integer(ms) and ms >= 0 -> :ok
      ms -> Mix.raise("invalid drain timeout: #{ms}")
    end

    case opts[:max_queue] do
      nil -> :ok
      n when is_integer(n) and n > 0 -> :ok
      n -> Mix.raise("invalid max queue: #{n}")
    end

    case opts[:log_level] do
      nil -> :ok
      level when level in @levels -> :ok
      level -> Mix.raise("invalid log level: #{level}")
    end

    case argv do
      [name] ->
        {name, opts}

      _ ->
        Mix.raise(
          "usage: mix oz_mcp.stdio MyApp.Server [--start-app] [--instance NAME] [--log-level LEVEL] " <>
            "[--drain-timeout MS] [--max-queue N]"
        )
    end
  end

  @doc false
  def fetch_server!(name) do
    module = Module.concat([name])

    if Code.ensure_loaded?(module) and function_exported?(module, :initialize_result, 0) do
      module
    else
      Mix.raise("#{name} is not an OzMcp server module")
    end
  end

  # Public for the tests: it gives the text that the task raises with.
  #
  @doc false
  def stop_message({:shutdown, :session_lost}),
    do: "the stdio transport stopped: the session is lost (start the server again)"

  def stop_message({:shutdown, :init_timeout}) do
    "the stdio transport stopped: the client did not send notifications/initialized " <>
      "(see the option session_init_timeout_ms)"
  end

  def stop_message({:shutdown, {:output_overflow, max}}) do
    "the stdio transport stopped: the stdout reader is too slow, more than #{max} " <>
      "messages wait for stdout (see the flag --max-queue)"
  end

  def stop_message(reason), do: "the stdio transport stopped: #{inspect(reason)}"

  defp set_log_level(nil), do: :ok

  defp set_log_level(level) when level in @levels,
    do: Logger.configure(level: String.to_existing_atom(level))
end
