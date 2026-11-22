#
# Owner of the task tables of one instance: a small process whose only
# work is the creation of the tables of the store, so it has no reason
# to crash. A crash of this process stops `Core` and its restart
# deletes the records of its server.
#
defmodule OzMcp.Tasks.Table do
  @moduledoc false

  use GenServer

  alias OzMcp.Tasks.Records

  def start_link({module, opts}) do
    name = {:via, Registry, {OzMcp.Instance.names(module), :tasks_table}}

    GenServer.start_link(__MODULE__, {module, opts}, name: name)
  end

  def child_spec({module, _opts} = arg) do
    %{
      id: {__MODULE__, module},
      start: {__MODULE__, :start_link, [arg]},
      restart: :permanent
    }
  end

  @impl true
  def init({module, opts}) do
    #
    # The facade creates the tables of the index only for a store that
    # does not own its index.
    #
    Records.init(opts.task_store, module)
    {:ok, :no_state}
  end
end
