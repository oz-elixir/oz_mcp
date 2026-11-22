#
# Test support server with the tool that sends requests to the client.
#
defmodule Support.Servers.Outbound do
  use OzMcp.Config.Server

  alias OzMcp.Instance

  server_info do
    name "ts-outbound-test"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.OutboundTest
    tool Support.Entities.Tools.ProgressTest
    tool Support.Entities.Tools.LogTest
  end

  capabilities do
    tasks do
      list %{}
      cancel %{}
      requests %{tools: %{call: %{}}}
    end
  end

  # The probe of a test is the pid under `{:roots_probe, session_id}` in
  # the Names Registry of the instance of `ctx` and its value is the mode
  # of the callback: `nil`, `:raise` or `:gate`. A global process name or
  # a global flag would reach a test that runs at the same time.
  #
  defp probe(ctx) do
    case Registry.lookup(Instance.names(ctx.instance), {:roots_probe, ctx.session_id}) do
      [{pid, mode}] -> {pid, mode}
      _other -> nil
    end
  rescue
    ArgumentError -> nil
  end

  def roots_list_changed(ctx) do
    case probe(ctx) do
      nil ->
        :ok

      {pid, mode} ->
        send(pid, {:roots_list_changed, ctx})
        run_mode(mode, pid)
    end
  end

  defp run_mode(:raise, _pid), do: raise("roots_list_changed failed")

  # A test can hold the callback: it reports its pid and waits for `:release`.
  #
  defp run_mode(:gate, pid) do
    send(pid, {:roots_blocked, self()})

    receive do
      :release -> :ok
    after
      10_000 -> :ok
    end
  end

  defp run_mode(_mode, _pid), do: :ok
end
