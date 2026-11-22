# Contributing to OzMcp

## How to contribute

1. For a large change, open an issue first to agree on the design.
2. Fork the repository and create a branch from `main`.
3. Follow the coding rules of
   [AGENTS.md](https://github.com/oz-elixir/oz_mcp/blob/main/AGENTS.md):
   one module per file in `lib/`, the format of the comments and of the
   moduledocs.
4. Run `mix ci` before you push. It must pass with no warning.
5. Open a pull request with one subject. CI must pass before the merge.

Do not report a security problem in an issue or a pull request: see
[SECURITY.md](SECURITY.md).

## The checks

The project needs Erlang/OTP `28.1` and Elixir `1.19.4`. The file
`.tool-versions` holds these versions.

The commands of the checks:

| Command | What it runs |
|---|---|
| `mix test` | all the tests except the tests that start an OS process |
| `mix test.unit` | the unit tests (the files with no `:e2e` tag) |
| `mix test.e2e` | the end-to-end tests over a real connection |
| `mix test.e2e.cowboy` | the end-to-end tests on the Cowboy listener |
| `mix test.stdio` | the tests that start an OS process |
| `mix test.cluster` | the cluster tests, which start other nodes |
| `mix test.sdk` | the TypeScript SDK client against the example server (needs Node and npm) |
| `mix ci` | the format check, the compile, `mix credo --strict` and the tests, with warnings as errors |
| `mix ci.full` | `mix ci`, then dialyzer and the docs in `MIX_ENV=dev` |
| `mix credo --strict` | the static analysis |
| `mix dialyzer` | the type analysis. Run it in `MIX_ENV=dev` |

The GitHub Actions workflow `.github/workflows/ci.yml` runs `lint`,
`dialyzer`, `docs`, `test-unit`, `test-e2e`, `test-e2e-cowboy`,
`test-sdk` and `conformance` in parallel. Every job blocks the build.
The conformance job fails when a scenario fails outside the baseline file
`test/conformance/expected_failures.yml`, or when a name of the baseline
passes. `mix ci.full` does not run `test-sdk` and `conformance`: they
need Node.

A new test follows two rules:

1. No `Process.sleep` for a wait. The suite counts the timed calls and
   a guard test keeps the count under a budget. Wait for an event:
   * a message that the code sends: `assert_receive`;
   * a sync point after a `cast`: `:sys.get_state(pid)`;
   * the end of a process: `ref = Process.monitor(pid)`, then
     `assert_receive {:DOWN, ^ref, _, _, _}`;
   * an event of the library: a `:telemetry` handler that sends a
     message (`Support.Helpers.TelemetryCapture` attaches one);
   * a check that nothing happens: `refute_receive message, timeout`,
     with a short timeout.
   `Process.sleep(:infinity)` in a spawned process is not a wait: the
   process must stay alive.
2. Give each instance a name of its own, so the test file can run with
   `async: true`:

   ```elixir
   name = Module.concat(MyServer, "T#{System.unique_integer([:positive])}")
   ```

## The conformance tool on a local machine

Start the conformance server (`OzMcp.E2E.ConformanceServer`, in the test
support). It declares the entities that the scenarios call by name:

```shell
mix conformance.serve 4040
```

The script prints `READY http://127.0.0.1:4040/mcp` and stays in front.
Run the conformance tool in another shell:

```shell
npx --yes @modelcontextprotocol/conformance@0.1.16 server \
  --url http://127.0.0.1:4040/mcp \
  --expected-failures test/conformance/expected_failures.yml
```

The tool ends with exit code `0` when every failed scenario is in the
baseline file `test/conformance/expected_failures.yml`. Each entry of
the file has a reason. Remove an entry when the scenario passes. The
`conformance` job in CI uses the same command and it blocks the build.
