# Starts the e2e example server on a fixed port for an external
# conformance tool. Usage:
#
#     MIX_ENV=test mix run test/e2e/support/serve.exs [port]
#
# The script prints a READY line when the endpoint answers, so a caller
# can wait for it before it starts the checks.
#
port = (System.argv() |> List.first() || "4040") |> String.to_integer()
server = OzMcp.E2E.ConformanceServer
instance = Module.concat(server, "Conformance")

children = [
  {OzMcp, server: server, name: instance, allowed_origins: ["http://127.0.0.1:#{port}"]},
  {Bandit,
   plug: {OzMcp.E2E.Router, instance: instance}, ip: :loopback, port: port, startup_log: false}
]

{:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)

IO.puts("READY http://127.0.0.1:#{port}/mcp")
Process.sleep(:infinity)
