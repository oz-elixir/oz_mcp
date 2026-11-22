defmodule OzMcp.Transport.Stdio.Reader do
  @moduledoc false

  alias OzMcp.Utils.Log

  def start_link(opts) do
    transport = Keyword.fetch!(opts, :transport)
    read = Keyword.fetch!(opts, :read)
    {:ok, spawn_link(fn -> loop(transport, read) end)}
  end

  defp loop(transport, read) do
    case safe_read(read) do
      {:ok, line} ->
        :ok = GenServer.call(transport, {:line, line}, :infinity)
        loop(transport, read)

      :eof ->
        GenServer.cast(transport, :eof)

      {:error, reason} ->
        #
        # A read error is not the end of the input: no line will ever
        # arrive, so the transport must stop, as it does for a raise.
        #
        text = inspect(reason, limit: 5, printable_limit: 100)
        exit({:read_failed, "cannot read stdin: " <> text})

      _other ->
        #
        # The value is not logged: it is the text of the client.
        #
        exit({:read_failed, "read returned an unexpected value"})
    end
  end

  # A failure of `read` ends the reader with a reason that holds the
  # type of the failure only (`Log.describe/3`): the raw reason of a VM
  # error does not say what happened.
  #
  defp safe_read(read) do
    read.()
  catch
    kind, reason -> exit({:read_failed, Log.describe(kind, reason, __STACKTRACE__)})
  end
end
