#
# Test support server whose config/0 fails on demand. The failure kind is
# read from the process dictionary of the calling (test) process: the
# router runs in the test process. Used to reach the last-resort handler of
# OzMcp.Router, which guards failures outside of the user callbacks.
#
defmodule Support.Servers.Failing do
  def config do
    case Process.get(:test_server_failure) do
      #
      # No failure is asked: the instance must boot, so the config is an
      # empty map. The router process asks for the config again during
      # the handling of the request.
      #
      nil -> %{}
      :raise -> raise "boom from config"
      :throw -> throw(:boom_from_config)
      :exit -> exit({:noproc, {GenServer, :call, [:gone, :request, 5000]}})
      :exit_shutdown -> exit(:shutdown)
    end
  end
end
