# Starts the SDK server on a fixed port. Usage:
#
#     MIX_ENV=test mix run test/e2e/support/serve_sdk.exs [port]
#
# The script prints a READY line when the endpoint answers.
#
port = (System.argv() |> List.first() || "4041") |> String.to_integer()
server = OzMcp.E2E.SdkServer
instance = Module.concat(server, "Sdk")

children = [
  {OzMcp,
   server: server,
   name: instance,
   allowed_origins: ["http://127.0.0.1:#{port}"],
   sse_max_stream_ms: 500,
   sse_retry_ms: 2_000},
  {Bandit,
   plug: {OzMcp.E2E.Router, instance: instance}, ip: :loopback, port: port, startup_log: false}
]

{:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)

IO.puts("READY http://127.0.0.1:#{port}/mcp")
Process.sleep(:infinity)
