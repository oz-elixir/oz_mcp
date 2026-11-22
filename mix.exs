defmodule OzMcp.MixProject do
  use Mix.Project

  @version "0.9.1"
  @source_url "https://github.com/oz-elixir/oz_mcp"

  def project do
    [
      app: :oz_mcp,
      version: @version,
      elixir: "~> 1.19",
      name: "OzMcp",
      description: "An Elixir framework for MCP servers (revision 2025-11-25)",
      source_url: @source_url,
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      docs: docs(),
      package: package(),
      aliases: aliases(),
      dialyzer: dialyzer()
    ]
  end

  # The Hex package holds the sources of `lib/` and the files a user of
  # the package needs. `.formatter.exs` is in it: it exports the
  # `locals_without_parens` of the DSL for `import_deps: [:oz_mcp]`.
  #
  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "MCP specification" => "https://modelcontextprotocol.io/specification/2025-11-25"
      },
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE SECURITY.md)
    ]
  end

  def cli do
    [
      preferred_envs: [
        bench: :bench,
        ci: :test,
        "ci.full": :test,
        "test.unit": :test,
        "test.e2e": :test,
        "test.e2e.cowboy": :test,
        "test.stdio": :test,
        "test.cluster": :test,
        "test.sdk": :test,
        "conformance.serve": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "test/e2e/support", "bench/support"]
  defp elixirc_paths(:bench), do: ["lib", "bench/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp aliases do
    [
      #
      # `test_helper.exs` excludes `:stdio_process` and `:flaky`, so the aliases
      # do not exclude them again. The e2e aliases select the tests by path, not
      # with `--only e2e`: an include of ExUnit wins over an exclude, so `--only`
      # would run the tests that `test_helper.exs` excludes.
      #
      "test.unit": ["test --exclude e2e --warnings-as-errors"],
      "test.e2e": ["test test/e2e --warnings-as-errors"],
      "test.e2e.cowboy": [
        "cmd env MIX_ENV=test OZ_MCP_HTTP_SERVER=cowboy mix test test/e2e --warnings-as-errors"
      ],
      "test.stdio": ["test --only stdio_process --warnings-as-errors"],
      "test.cluster": ["test --only cluster --warnings-as-errors"],
      #
      # Runs the TypeScript SDK client against the example server. It needs
      # Node and npm. It is not part of `ci`, so a machine without Node can
      # still run the Elixir checks.
      #
      "test.sdk": [
        "cmd npm ci --prefix test/sdk_client",
        "cmd npm test --prefix test/sdk_client"
      ],
      bench: ["run bench/run.exs"],
      docs: ["run --no-start tools/gen_docs.exs", "docs"],
      ci: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test --warnings-as-errors"
      ],
      "ci.full": [
        "ci",
        #
        # The task `test` of `ci` already ran in this process, so a second
        # `test` task here does nothing. The cluster tests start a new process.
        #
        "cmd env MIX_ENV=test mix test.cluster",
        "cmd env MIX_ENV=test mix test.e2e.cowboy",
        "cmd env MIX_ENV=dev mix dialyzer",
        "cmd env MIX_ENV=dev mix docs --warnings-as-errors"
      ],
      "conformance.serve": ["run test/e2e/support/serve.exs"]
    ]
  end

  # The PLT stays under `_build/`, which is already git-ignored. Dialyzer runs
  # in `MIX_ENV=dev`, so it checks `lib/` only. `plt_add_apps: [:mix, :ex_unit]`
  # covers the use of `Mix` in `lib/mix/tasks/` and the use of `ExUnit` in
  # `lib/oz_mcp/testing.ex`. An entry of the ignore file that no warning needs
  # anymore is an error, so the list cannot grow stale.
  #
  defp dialyzer do
    [
      plt_local_path: "_build/plts",
      plt_core_path: "_build/plts",
      plt_add_apps: [:mix, :ex_unit],
      flags: [:error_handling, :unknown, :unmatched_returns],
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      skip_undefined_reference_warnings_on: [
        #
        # The specs of these files name types of internal modules (or a
        # delegate target of an internal module) and a spec cannot name
        # them in another way.
        #
        "lib/oz_mcp/instance.ex",
        "lib/oz_mcp/auth/gate.ex",
        "lib/oz_mcp/context.ex",
        "lib/oz_mcp/sessions.ex",
        "lib/oz_mcp/transport/http/cors.ex",
        "lib/oz_mcp/transport/http/response.ex",
        "lib/oz_mcp/utils/template_uri.ex"
      ],
      extras: [
        "README.md",
        "CHANGELOG.md",
        "CONFORMANCE.md",
        "SECURITY.md",
        "CONTRIBUTING.md",
        "LICENSE",
        "guides/introduction/getting_started.md",
        "guides/servers/declare_a_server.md",
        "guides/entities/overview.md",
        "guides/entities/tools.md",
        "guides/entities/resources.md",
        "guides/entities/templates.md",
        "guides/entities/prompts.md",
        "guides/entities/completions.md",
        "guides/runtime/runtime_options.md",
        "guides/runtime/http_transport.md",
        "guides/runtime/stdio_transport.md",
        "guides/runtime/authorization.md",
        "guides/runtime/tasks.md",
        "guides/runtime/cluster.md",
        "guides/runtime/client_requests.md",
        "guides/runtime/notifications.md",
        "guides/runtime/telemetry.md",
        "guides/development/testing.md",
        "guides/long_examples/tool_examples.md",
        "guides/long_examples/resource_examples.md",
        "guides/long_examples/template_examples.md",
        "guides/long_examples/prompt_examples.md"
      ],
      groups_for_extras: [
        Introduction: ~r{guides/introduction/},
        Servers: ~r{guides/servers/},
        Entities: ~r{guides/entities/},
        Runtime: ~r{guides/runtime/},
        Development: ~r{guides/development/},
        "Long Examples": ~r{guides/long_examples/}
      ],
      groups_for_modules: [
        Server: [OzMcp.Config.Server, OzMcp.Config.Server.DSL],
        Entities: [
          OzMcp.Config.Tool,
          OzMcp.Config.Tool.DSL,
          OzMcp.Config.Resource,
          OzMcp.Config.Resource.DSL,
          OzMcp.Config.Template,
          OzMcp.Config.Template.DSL,
          OzMcp.Config.Prompt,
          OzMcp.Config.Prompt.DSL
        ],
        "Runtime and transports": [
          OzMcp,
          OzMcp.Instance,
          OzMcp.Router,
          OzMcp.Transport.Stdio,
          OzMcp.Transport.Stdio.Console,
          Mix.Tasks.OzMcp.Stdio
        ],
        "Callback API": [
          OzMcp.Context,
          OzMcp.Notify,
          OzMcp.LogLevel,
          OzMcp.Sessions,
          OzMcp.Tasks,
          OzMcp.Client,
          OzMcp.Outbound,
          OzMcp.Tasks.Context,
          OzMcp.Utils.Error
        ],
        Authorization: [
          OzMcp.Auth,
          OzMcp.Auth.Principal,
          OzMcp.Auth.Challenge,
          OzMcp.Auth.Metadata,
          OzMcp.Auth.Scopes,
          OzMcp.Pipeline.Bound
        ],
        Stores: [
          OzMcp.Session.Snapshot,
          OzMcp.Session.Snapshot.None,
          OzMcp.PubSub,
          OzMcp.PubSub.Registry,
          OzMcp.PubSub.PG,
          OzMcp.Tasks.StoreBehaviour,
          OzMcp.Tasks.EtsStore
        ],
        Structs: ~r/^OzMcp\.Structs\./,
        Testing: [OzMcp.Testing]
      ]
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.20"},
      {:jsv, "~> 0.28.0"},
      {:telemetry, "~> 1.2"},
      {:ex_doc, "~> 0.40.3", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:bandit, "~> 1.15", only: :test},
      {:plug_cowboy, "~> 2.9", only: :test},
      {:req, "~> 0.5", only: :test},
      {:stream_data, "~> 1.4", only: [:dev, :test]}
    ]
  end
end
