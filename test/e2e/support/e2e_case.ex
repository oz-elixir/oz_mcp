#
# The case template of the end-to-end suite.
#
# Each test starts its own instance (with a name of its own) and its own HTTP listener (Bandit or
# Cowboy, on a random port) and talks to it with `OzMcp.E2E.Client` over a real
# connection. The instance and the listener run under the ExUnit test
# supervisor: they stop at the end of the test, even on a failure.
#
# A test can pick its server and its runtime options with tags:
#
#     @tag server: MyServer, server_opts: %{max_sessions: 1}
#
# The default is `OzMcp.E2E.Server` with no runtime option.
#
# The HTTP server of the listener comes from the tag `http_server`
# (`:bandit` or `:cowboy`), or from the variable `OZ_MCP_HTTP_SERVER`
# of the run when the tag is absent. Bandit is the default. Extra
# options of the listener go with the tag `http_server_opts`:
#
#     @tag http_server: :cowboy, http_server_opts: [protocol_options: []]
#
defmodule OzMcp.E2ECase do
  use ExUnit.CaseTemplate
  alias Support.Helpers.Utils

  using do
    quote do
      import OzMcp.E2ECase

      alias OzMcp.E2E.Client
      alias OzMcp.E2E.RawHttp

      @moduletag :e2e
    end
  end

  setup context do
    server = Map.get(context, :server, OzMcp.E2E.Server)
    server_opts = Map.get(context, :server_opts, %{})

    instance = Module.concat(server, "T#{System.unique_integer([:positive])}")

    Utils.start_instance(
      server,
      [name: instance, allowed_origins: ["http://localhost"]] ++ Map.to_list(server_opts)
    )

    kind = OzMcp.E2E.HttpServer.kind(context)
    extra = Map.get(context, :http_server_opts, [])

    {spec, port_fun} =
      OzMcp.E2E.HttpServer.child(kind, {OzMcp.E2E.Router, instance: instance}, extra)

    listener = start_supervised!(spec)
    port = port_fun.(listener)

    Support.Entities.Tools.TaskSlowTest.use_instance(instance)

    {:ok,
     base_url: "http://127.0.0.1:#{port}/mcp",
     server: server,
     instance: instance,
     http_server: kind}
  end

  # A test waits for a state of the server that no message announces:
  # `fun` runs until it is true, with a short wait between two tries.
  # `tries` bounds the wait at `tries * 10` milliseconds.
  #
  def wait_until(what, fun, tries \\ 1_500)

  def wait_until(what, _fun, 0), do: ExUnit.Assertions.flunk("timeout while waiting for: #{what}")

  def wait_until(what, fun, tries) do
    if Utils.eventually(fun, tries * 10) do
      :ok
    else
      ExUnit.Assertions.flunk(what <> " was not met in time")
    end
  end
end
