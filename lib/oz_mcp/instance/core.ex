#
# The owner of the shared state of one instance: the three Registries
# and the owner of the ETS tables of the task store. The four children
# share one fate, so a crash of one restarts all four (`:one_for_all`).
# `max_restarts: 0`: the first crash of a child stops this supervisor and
# the `Instance` supervisor (`:rest_for_one`) restarts it and the
# PubSub and Workers after it. Without this, `Core` would restart its
# children alone and the sessions would keep dead Registries.
#
defmodule OzMcp.Instance.Core do
  @moduledoc false

  use Supervisor

  alias OzMcp.Instance

  def start_link(config), do: Supervisor.start_link(__MODULE__, config)

  def child_spec(config) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [config]}, type: :supervisor}
  end

  @impl true
  def init(config) do
    name = config.name
    partitions = System.schedulers_online()

    children = [
      registry_spec(Instance.names(name),
        keys: :unique,
        partitions: partitions,
        meta: [config: config]
      ),
      registry_spec(Instance.topics(name), keys: :duplicate, partitions: partitions),
      registry_spec(Instance.principals(name), keys: :duplicate, partitions: 1),
      {OzMcp.Tasks.Table, {name, config.opts}}
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
  end

  defp registry_spec(name, opts) do
    opts = Keyword.put(opts, :name, name)

    %{
      id: name,
      start: {Instance, :start_registry, [opts]},
      type: :supervisor,
      modules: [Registry]
    }
  end
end
