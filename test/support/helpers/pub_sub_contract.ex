#
# The cases of the `OzMcp.PubSub` behaviour that every implementation must
# pass. The module that uses it gives these options:
#
#   * `module` - the implementation of `OzMcp.PubSub`.
#   * `members` - a function `(instance, topic) -> [pid()]` that gives the
#     processes that are in the topic.
#
# The cases read the instance from the `:server` of the test context.
#
defmodule Support.Helpers.PubSubContract do
  defmacro __using__(opts) do
    module = Keyword.fetch!(opts, :module)
    members = Keyword.fetch!(opts, :members)

    quote do
      test "a subscriber gets the broadcast of its topic only", %{server: server} do
        :ok = unquote(module).subscribe(server, :initialized)
        :ok = unquote(module).broadcast(server, {:subscription, "x"}, :other)
        :ok = unquote(module).broadcast(server, :initialized, :mine)

        assert_receive {:oz_mcp_broadcast, :mine}
        refute_receive {:oz_mcp_broadcast, :other}, 50
      end

      test "unsubscribe stops the messages", %{server: server} do
        :ok = unquote(module).subscribe(server, {:principal, :k})
        :ok = unquote(module).unsubscribe(server, {:principal, :k})
        :ok = unquote(module).broadcast(server, {:principal, :k}, :late)

        refute_receive {:oz_mcp_broadcast, _}, 50
      end

      test "a process that ends leaves the topic", %{server: server} do
        topic = {:subscription, "leaves"}

        {pid, ref} =
          spawn_monitor(fn ->
            :ok = unquote(module).subscribe(server, topic)

            receive do
              :stop -> :ok
            end
          end)

        assert wait_for_members(unquote(members), server, topic, 1)

        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

        assert wait_for_members(unquote(members), server, topic, 0)
      end

      test "a second subscribe is not a hidden bug for the session", %{server: server} do
        :ok = unquote(module).subscribe(server, :initialized)
        :ok = unquote(module).subscribe(server, :initialized)
        :ok = unquote(module).broadcast(server, :initialized, :twice)

        assert_receive {:oz_mcp_broadcast, :twice}
        assert_receive {:oz_mcp_broadcast, :twice}
        refute_receive {:oz_mcp_broadcast, :twice}, 50
      end

      defp wait_for_members(members, server, topic, count, deadline \\ nil) do
        deadline = deadline || System.monotonic_time(:millisecond) + 5_000

        if length(members.(server, topic)) == count do
          true
        else
          if System.monotonic_time(:millisecond) >= deadline do
            false
          else
            receive do
            after
              10 -> wait_for_members(members, server, topic, count, deadline)
            end
          end
        end
      end
    end
  end
end
