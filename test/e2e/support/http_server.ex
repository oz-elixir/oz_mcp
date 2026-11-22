#
# The HTTP listener of an e2e test. The server is `:bandit` (the
# default) or `:cowboy`. The caller supervises the listener with
# `start_supervised!/1` and reads its port with the function that
# `child/3` gives.
#
defmodule OzMcp.E2E.HttpServer do
  @type kind :: :bandit | :cowboy

  # The server of a test: the tag `http_server` of the test first, then
  # the variable `OZ_MCP_HTTP_SERVER` of the run when the tag is absent.
  #
  @spec kind(map()) :: kind()
  def kind(context) do
    case Map.get(context, :http_server) || System.get_env("OZ_MCP_HTTP_SERVER", "bandit") do
      value when value in [:bandit, "bandit"] -> :bandit
      value when value in [:cowboy, "cowboy"] -> :cowboy
    end
  end

  # The server of the run, from the variable `OZ_MCP_HTTP_SERVER` only.
  # A test file reads it at compile time, when it marks a test for one
  # server with a `skip` tag: an `exclude` filter cannot skip a test that
  # an `--only` filter selects.
  #
  @spec env_kind() :: kind()
  def env_kind, do: kind(%{})

  # A child spec of the listener and a function that reads its port after
  # the start. `extra` goes to the listener as it is (for example the
  # `protocol_options` of Cowboy).
  #
  @spec child(kind(), module() | {module(), keyword()}, keyword()) ::
          {Supervisor.child_spec(), (pid() -> :inet.port_number())}
  def child(kind, plug, extra \\ [])

  def child(:bandit, plug, extra) do
    spec = {Bandit, [plug: plug, ip: :loopback, port: 0, startup_log: false] ++ extra}

    port_fun = fn pid ->
      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      port
    end

    {spec, port_fun}
  end

  # The ref is unique for each listener: `Plug.Cowboy` uses it as the id
  # of the child and as the name of the Ranch listener and the tests
  # run at the same time.
  #
  def child(:cowboy, plug, extra) do
    ref = :"oz_mcp_e2e_#{System.unique_integer([:positive])}"

    spec =
      {Plug.Cowboy, [scheme: :http, plug: plug, ref: ref, ip: {127, 0, 0, 1}, port: 0] ++ extra}

    {spec, fn _pid -> :ranch.get_port(ref) end}
  end
end
