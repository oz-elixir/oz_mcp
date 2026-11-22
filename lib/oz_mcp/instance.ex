defmodule OzMcp.Instance do
  @moduledoc """
  Supervisor of a single MCP server instance.

  Each instance owns its own names and registries: a unique `Names`
  Registry (which also carries the `%OzMcp.Instance.Config{}` as meta
  data), a duplicate `Topics` Registry and a duplicate `Principals`
  Registry (which holds one entry for each open session of a principal).
  The instance is a tree of three levels. `Core` owns the three
  Registries and the owner of the task table. `PubSub` holds the processes
  of the `:pubsub` module (only when the module has them). `Workers` holds
  the supervisor of the callbacks, the supervisor of the sessions, the
  reaper, the supervisor of the tasks and the processes of the snapshot.

  Use the child spec `{OzMcp, opts}` to embed one or more instances into
  the supervision tree of the host application:

      children = [
        {OzMcp, server: MyApp.McpServer, allowed_origins: ["http://localhost:4000"]},
        {Bandit, plug: MyApp.Router, port: 4000}
      ]
  """

  use Supervisor

  alias OzMcp.Instance.Config

  @type t :: atom()

  @doc false
  def child_spec(opts) do
    config = Config.parse!(opts)

    %{
      id: {__MODULE__, config.name},
      start: {__MODULE__, :start_link, [config]},
      type: :supervisor
    }
  end

  @doc false
  @spec start_link(Config.t()) :: {:ok, pid()} | {:error, term()}
  def start_link(%Config{} = config) do
    name = Module.concat(config.name, Instance)
    await_stale(name)
    Supervisor.start_link(__MODULE__, config, name: name)
  end

  # A `:kill` of the supervisor of an instance does not wait for its
  # children: a restart by the host can run while the old children still
  # stop, so the new start meets names that the old process tree still
  # owns (the name of the supervisor, the names of the Registries and
  # the children of the PubSub module). Without the wait, the kill
  # tests of `OzMcp.RuntimeRestartTest` fail with `already started`;
  # the wait is bounded and ends after all its children ended.
  #
  @stale_wait_ms 1_000

  defp await_stale(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> wait_down(pid, System.monotonic_time(:millisecond) + @stale_wait_ms)
    end
  end

  @impl true
  def init(%Config{name: name} = config) do
    pubsub =
      case OzMcp.Instance.PubSub.specs(name, config) do
        [] -> []
        specs -> [{OzMcp.Instance.PubSub, {name, specs}}]
      end

    children =
      [{OzMcp.Instance.Core, config}] ++ pubsub ++ [{OzMcp.Instance.Workers, config}]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # A `:kill` of a process that owns a name leaves the name held for a
  # short time, so an immediate restart of the same name gets
  # `{:error, {:already_started, pid}}`: the start waits for the old
  # process to end and tries again. The Registries, the `:pg` scope
  # of `OzMcp.PubSub.PG` and the `Workers` supervisor use this retry.
  # Without it, the kill tests of `OzMcp.RuntimeRestartTest` fail with
  # `already started`.
  #
  @doc false
  @spec start_retry((-> {:ok, pid()} | {:error, term()})) :: {:ok, pid()} | {:error, term()}
  def start_retry(start_fun) when is_function(start_fun, 0),
    do: start_retry(start_fun, @stale_wait_ms)

  @doc false
  @spec start_retry((-> {:ok, pid()} | {:error, term()}), non_neg_integer()) ::
          {:ok, pid()} | {:error, term()}
  def start_retry(start_fun, wait_ms)
      when is_function(start_fun, 0) and is_integer(wait_ms) and wait_ms >= 0,
      do: start_retry_until(start_fun, System.monotonic_time(:millisecond) + wait_ms)

  defp start_retry_until(start_fun, deadline) do
    case start_fun.() do
      {:error, reason} = error ->
        with pid when is_pid(pid) <- stale_pid(reason),
             :down <- wait_down(pid, deadline) do
          start_retry_until(start_fun, deadline)
        else
          _other -> error
        end

      other ->
        other
    end
  end

  @doc false
  def start_registry(opts), do: start_retry(fn -> Registry.start_link(opts) end)

  defp stale_pid({:already_started, pid}) when is_pid(pid), do: pid
  defp stale_pid({:shutdown, inner}), do: stale_pid(inner)
  defp stale_pid({:failed_to_start_child, _child, inner}), do: stale_pid(inner)
  defp stale_pid(_other), do: nil

  defp wait_down(pid, deadline) do
    ref = Process.monitor(pid)
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :down
    after
      remaining ->
        Process.demonitor(ref, [:flush])
        :alive
    end
  end

  @doc """
  The name of the instance's `Names` Registry.
  """
  @spec names(t()) :: atom()
  def names(instance), do: Module.concat(instance, Names)

  @doc """
  The name of the instance's `Topics` Registry.
  """
  @spec topics(t()) :: atom()
  def topics(instance), do: Module.concat(instance, Topics)

  @doc """
  The name of the instance's `Principals` Registry. It holds one entry for
  each open session of a principal, under the key of the principal.
  """
  @spec principals(t()) :: atom()
  def principals(instance), do: Module.concat(instance, Principals)

  @doc """
  A via tuple that addresses `key` inside the instance's `Names` Registry.
  """
  @spec via(t(), term()) :: {:via, Registry, {atom(), term()}}
  def via(instance, key), do: {:via, Registry, {names(instance), key}}

  @doc """
  The config of a running instance, or `:not_running`. A Registry that does
  not run gives `:not_running` and never raises.
  """
  @spec config(t()) :: {:ok, Config.t()} | :not_running
  def config(instance) do
    case Registry.meta(names(instance), :config) do
      {:ok, config} -> {:ok, config}
      :error -> :not_running
    end
  rescue
    ArgumentError -> :not_running
  end

  # The config of a request. A caller that has a config, a context or a conn
  # with the config uses it. A caller out of the pipeline (a test, a user
  # call) reads the Registry.
  #
  @doc false
  @spec config(t(), OzMcp.Context.t() | Plug.Conn.t() | Config.t() | nil) ::
          {:ok, Config.t()} | :not_running
  def config(_instance, %Config{} = config), do: {:ok, config}

  def config(_instance, %OzMcp.Context{config: %Config{} = config}), do: {:ok, config}

  def config(_instance, %Plug.Conn{private: %{oz_mcp_config: %Config{} = config}}),
    do: {:ok, config}

  def config(instance, _other), do: config(instance)

  @doc """
  The server module of an instance. An instance that does not run (or a
  module that is not the name of an instance) answers with its own name:
  the name of an instance is the server module by default.
  """
  @spec server_module(t()) :: module()
  def server_module(instance) do
    case config(instance) do
      {:ok, %{server: server}} -> server
      :not_running -> instance
    end
  end

  @doc """
  Looks up a pid that is registered under `key` in the instance's `Names` Registry.
  A process that died and that the Registry still holds is not running.
  """
  @spec whereis(t(), term()) :: {:ok, pid()} | :not_running
  def whereis(instance, key) do
    case Registry.lookup(names(instance), key) do
      [{pid, _value}] -> if Process.alive?(pid), do: {:ok, pid}, else: :not_running
      [] -> :not_running
    end
  rescue
    ArgumentError -> :not_running
  end

  @doc """
  Runs a match specification on the instance's `Names` Registry, or gives
  `[]` when the instance is not running.
  """
  @spec select(t(), [tuple()]) :: [term()]
  def select(instance, spec) do
    Registry.select(names(instance), spec)
  rescue
    ArgumentError -> []
  end

  @doc """
  The static options of the server of the instance (`{:ok, opts}`), or
  `:not_running` when the instance is not running.
  """
  @spec fetch_opts(t()) :: {:ok, Config.opts()} | :not_running
  def fetch_opts(instance) do
    with {:ok, %Config{} = config} <- config(instance), do: {:ok, config.opts}
  end

  @doc """
  The static options of the instance, or their defaults when the instance
  is not running. A caller that must not hide that situation uses
  `fetch_opts/1`.
  """
  @spec opts(t()) :: Config.opts()
  def opts(instance) do
    case fetch_opts(instance) do
      {:ok, opts} -> opts
      :not_running -> Config.default_opts()
    end
  end
end
