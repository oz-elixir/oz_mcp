#
# The supervisor of the processes of the `:pubsub` module.
# It has its own place in the tree: a crash of one of these processes
# loses the group memberships of the sessions, so the sessions must
# stop (the Workers restart after it). The task records live in Core
# and they stay. `max_restarts: 0`: the first crash of a child stops this
# supervisor and the `Instance` supervisor (`:rest_for_one`) restarts it
# and the Workers after it.
#
defmodule OzMcp.Instance.PubSub do
  @moduledoc false

  use Supervisor

  def start_link({name, specs}), do: Supervisor.start_link(__MODULE__, {name, specs})

  def child_spec({_name, _specs} = arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, type: :supervisor}
  end

  @doc false
  @spec specs(atom(), OzMcp.Instance.Config.t()) :: [Supervisor.child_spec()]
  def specs(name, %{opts: %{pubsub: module}}) do
    if Code.ensure_loaded?(module) and function_exported?(module, :child_specs, 1),
      do: module.child_specs(name),
      else: []
  end

  @impl true
  def init({_name, specs}), do: Supervisor.init(specs, strategy: :one_for_one, max_restarts: 0)
end
