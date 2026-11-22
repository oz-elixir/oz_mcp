Support.Helpers.LogHandler.install()

# The holder of the table of the test snapshot store: one process for the
# whole run. The state of the store is keyed by the name of the instance,
# so the tests that run at the same time hold their state apart.
#
{:ok, _} = Support.Helpers.PersistentSnapshot.start_link()

ExUnit.configure(capture_log: true)

# `:stdio_process`: the tests that run the stdio task as an OS process.
# The tests run at the same time: a wait for a message is much longer than the
# default of 100 ms, so a loaded machine does not make a test fail.
#
# `:bench`: the smoke test of the benchmark code. It runs the scenarios
# of the benchmark with a small count and takes longer than a unit test.
# Run it with `mix test --only bench`.
#
# `:cluster`: the tests that start a second node. They need `epmd` and a free
# loopback address. Run them with `mix test.cluster`.
#
# `:flaky`: the tests that fail from time to time (a race or a time limit
# on a loaded machine). They wait for a fix. Run them with
# `mix test --only flaky`.
#
# `max_cases`: as many test modules at the same time as schedulers, so the
# tests do not compete for the CPU more than the machine allows.
#
ExUnit.start(
  exclude: [:stdio_process, :bench, :cluster, :flaky],
  assert_receive_timeout: 5_000,
  max_cases: System.schedulers_online()
)

# The distribution starts only for the tag `:cluster` (`mix test.cluster`).
# Mix gives its options to ExUnit before it loads this file, so the tag of the
# command line is in the configuration here.
#
if :cluster in Keyword.get(ExUnit.configuration(), :include, []) do
  epmd = System.find_executable("epmd") || raise "the :cluster tests need epmd in the PATH"
  {_, 0} = System.cmd(epmd, ["-daemon"])
  {:ok, _} = Node.start(:"oz_mcp_test@127.0.0.1", :longnames)
end
