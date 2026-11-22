defmodule OzMcp.Transport.Stdio.Console do
  @moduledoc """
  Puts the standard input and output of the process in a shape the stdio
  transport can use.

  A server on stdio must write JSON-RPC messages to stdout and nothing
  else: one log line or one stray `IO.puts/1` breaks the protocol of the
  client. `open/0` returns the two functions the transport takes as its
  `:read` and `:write` options and prepares the environment: the
  encoding of the standard IO device becomes UTF-8, the default handler
  of the `Logger` moves to stderr and the group leader of the calling
  process moves to the standard error device, so every process that
  starts later writes its stray output to stderr too.

  Call it once, first thing, in the process that starts the transport.
  """

  @spec open() :: %{
          read: (-> {:ok, binary()} | :eof | {:error, term()}),
          write: (iodata() -> :ok | {:error, term()})
        }
  def open do
    #
    # The device must be taken by pid before the group leader moves: the
    # functions below must keep writing to the real stdout.
    #
    device = Process.whereis(:user)

    # The default encoding of the standard IO device depends on the locale.
    #
    :ok = :io.setopts(device, encoding: :unicode)

    redirect_logger()

    # Every process that starts after this call inherits the group leader.
    #
    :erlang.group_leader(Process.whereis(:standard_error), self())

    %{read: reader(device), write: writer(device)}
  end

  @doc """
  Moves the default handler of the `Logger` to stderr and keeps its
  level, formatter and filters. Does nothing when there is no default
  handler.
  """
  @spec redirect_logger() :: :ok
  def redirect_logger do
    case :logger.get_handler_config(:default) do
      {:ok, config} ->
        :ok = :logger.remove_handler(:default)

        :ok =
          :logger.add_handler(:default, config.module, %{
            config: Map.put(config.config, :type, :standard_error),
            level: config.level,
            formatter: config.formatter,
            filters: config.filters,
            filter_default: config.filter_default
          })

      _ ->
        :ok
    end
  end

  @doc """
  The function the transport takes as its `:read` option: one line of
  stdin per call, as `{:ok, line}`, `:eof`, or `{:error, reason}`.
  """
  @spec reader(device :: pid() | atom()) :: (-> {:ok, binary()} | :eof | {:error, term()})
  def reader(device) do
    fn ->
      case IO.read(device, :line) do
        :eof -> :eof
        {:error, reason} -> {:error, reason}
        data -> {:ok, IO.chardata_to_string(data)}
      end
    end
  end

  @doc """
  The function the transport takes as its `:write` option: it writes the
  message to stdout, `:ok`, or `{:error, reason}` when the write fails.
  """
  @spec writer(device :: pid() | atom()) :: (iodata() -> :ok | {:error, term()})
  def writer(device) do
    fn iodata ->
      try do
        IO.write(device, iodata)
        :ok
      catch
        _kind, reason -> {:error, reason}
      end
    end
  end
end
