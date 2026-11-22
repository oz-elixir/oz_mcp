#
# Finds the supervisors of the levels of an instance tree.
#
defmodule Support.Helpers.TreeProbe do
  alias OzMcp.Instance.Core
  alias OzMcp.Instance.PubSub
  alias OzMcp.Instance.Workers

  # The pid of the Core supervisor of the instance, or nil.
  #
  def core(name), do: find(name, Core)

  # The pid of the Workers supervisor of the instance, or nil.
  #
  def workers(name), do: find(name, Workers)

  # The pid of the PubSub supervisor of the instance, or nil when it has none.
  #
  def pubsub(name), do: find(name, PubSub)

  defp find(name, id) do
    instance = Module.concat(name, Instance)

    if is_pid(Process.whereis(instance)) do
      instance
      |> Supervisor.which_children()
      |> Enum.find_value(fn
        {^id, pid, :supervisor, _modules} when is_pid(pid) -> pid
        _other -> nil
      end)
    end
  end
end
