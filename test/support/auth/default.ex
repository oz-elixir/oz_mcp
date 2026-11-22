#
# A reference verifier for the tests. It matches fixed tokens to fixed
# principals and shows the shape of a real implementation.
#
defmodule Support.Auth.Default do
  @behaviour OzMcp.Auth

  alias OzMcp.Auth.{Challenge, Principal}

  @audience "https://mcp.example.com/mcp"

  @tokens %{
    "alice-token" => {"https://issuer.test", "alice", ["files:read"], @audience},
    "alice-admin" => {"https://issuer.test", "alice", ["files:read", "files:write"], @audience},
    "alice-root" =>
      {"https://issuer.test", "root", ["files:read", "files:write", "admin"], @audience},
    "bob-token" => {"https://issuer.test", "bob", ["files:read"], @audience},
    "upper-audience" =>
      {"https://issuer.test", "alice", ["files:read"], "HTTPS://MCP.EXAMPLE.COM/mcp"},
    "other-audience" =>
      {"https://issuer.test", "alice", ["files:read"], "https://other.example.com/mcp"},
    "no-audience" => {"https://issuer.test", "alice", ["files:read"], nil},
    "expired-token" => :expired
  }

  # Registers a token for a principal and gives the token. The options: the
  # `:subject` (default `"alice"`), the `:scopes` (default `["files:read"]`),
  # the `:audiences` (default the audience of the test servers) and the
  # `:issuer`.
  #
  # A test that needs a token of its own registers one: the token holds a
  # number that is unique in the test run and the state of the verifier
  # (the expiry times, the revoked tokens) is keyed by the token, so the
  # state of one test never touches the state of another. A registered
  # token needs no reset: no other test knows it. Each value has its own
  # :persistent_term key (one key for a map would lose the write of a test
  # that runs at the same time).
  #
  def register_token(opts \\ []) do
    token = "test-token-#{System.unique_integer([:positive])}"

    principal =
      {
        Keyword.get(opts, :issuer, "https://issuer.test"),
        Keyword.get(opts, :subject, "alice"),
        Keyword.get(opts, :scopes, ["files:read"]),
        Keyword.get(opts, :audiences, @audience)
      }

    :persistent_term.put({__MODULE__, :token, token}, principal)
    token
  end

  @impl true
  def authenticate(conn, _server) do
    with {:ok, token} <- OzMcp.Auth.bearer_token(conn) do
      if revoked?(token) do
        {:error, Challenge.invalid_token("token revoked")}
      else
        case Map.get(@tokens, token) || registered(token) do
          nil ->
            {:error, Challenge.invalid_token("unknown token")}

          :expired ->
            {:error, Challenge.invalid_token("token expired")}

          {issuer, subject, scopes, audiences} ->
            {:ok,
             Principal.new!(
               issuer: issuer,
               subject: subject,
               scopes: scopes,
               audiences: audiences,
               expires_at: expiry(token)
             )}
        end
      end
    end
  end

  # Tests can remove a token (a session token that the authorization
  # server has expired): every later authenticate/2 refuses it. The list
  # lives in :persistent_term, so a test must clean it up (reset/0).
  #
  def revoke(token), do: :persistent_term.put({__MODULE__, :revoked, token}, true)

  # Tests can set the expiry of a token: the principal of `token` expires
  # at this Unix time (seconds, a float is allowed). The list lives in
  # :persistent_term, so a test must clean it up (reset/0).
  #
  def expire_at(token, unix_seconds),
    do: :persistent_term.put({__MODULE__, :expiry, token}, unix_seconds)

  def reset do
    for {{__MODULE__, kind, _token} = key, _value} <- :persistent_term.get(),
        kind in [:revoked, :expiry] do
      :persistent_term.erase(key)
    end

    :ok
  end

  defp revoked?(token), do: :persistent_term.get({__MODULE__, :revoked, token}, false)

  defp expiry(token), do: :persistent_term.get({__MODULE__, :expiry, token}, nil)

  defp registered(token), do: :persistent_term.get({__MODULE__, :token, token}, nil)

  # A task-augmented call records the bound entity the callback received,
  # under the subject of the principal of the call: the tests check that
  # authorize/3 gets a %Bound{} of kind :tool whose task metadata carries
  # the ttl of the request. A test that reads the bound uses a subject of
  # its own (a registered token), so the tests run apart. The clause comes
  # before the plain tools/call clauses, which match a task-augmented
  # bound too.
  #
  @impl true
  def authorize(
        principal,
        "tools/call",
        %OzMcp.Pipeline.Bound{kind: :tool, task: %{ttl: _}} = bound
      ) do
    :persistent_term.put({__MODULE__, :task_bound, principal.subject}, bound)
    :ok
  end

  # The scope rule of the tests: a write needs files:write. The guarded
  # tool is one of the tools of the test servers: the authorization step
  # runs after the bind stage, which resolves the tool.
  #
  def authorize(principal, "tools/call", %OzMcp.Pipeline.Bound{kind: :tool, name: "get_date"}) do
    if Principal.scope?(principal, "files:write") do
      :ok
    else
      {:error, {:insufficient_scope, ["files:read", "files:write"], "write permission needed"}}
    end
  end

  # A raise for a tool that carries required scopes: only the tests of the
  # scope step use the marker argument, so the clause never fires for the
  # other servers.
  #
  def authorize(_principal, "tools/call", %OzMcp.Pipeline.Bound{
        kind: :tool,
        name: "write_file",
        arguments: %{"path" => "crash"}
      }),
      do: raise("authorize failure")

  # Markers for the other answers of the contract. The step runs before
  # the handler: the marked requests never reach it.
  #
  def authorize(_principal, "resources/read", %OzMcp.Pipeline.Bound{
        kind: :resource,
        name: "file:///marketing.md"
      }),
      do: {:error, :forbidden}

  def authorize(_principal, "tasks/list", %OzMcp.Pipeline.Bound{params: %{"cursor" => "crash"}}),
    do: raise("authorize failure")

  def authorize(
        _principal,
        "tasks/list",
        %OzMcp.Pipeline.Bound{params: %{"cursor" => "bad-return"}}
      ),
      do: :not_an_allowed_answer

  # A scope that breaks the scope-token syntax: building the challenge
  # must fail and the framework must answer a server error, never crash.
  #
  def authorize(
        _principal,
        "tasks/list",
        %OzMcp.Pipeline.Bound{params: %{"cursor" => "bad-scope"}}
      ),
      do: {:error, {:insufficient_scope, ["files:read files:write"]}}

  # A description that breaks the contract: building the challenge must
  # fail and the framework must answer a server error, never crash.
  #
  def authorize(
        _principal,
        "tasks/list",
        %OzMcp.Pipeline.Bound{params: %{"cursor" => "bad-description"}}
      ),
      do: {:error, {:insufficient_scope, ["files:read"], 123}}

  # Markers for the authorize step of `initialize`, which runs before the
  # session is created. The name of the client selects the answer.
  #
  def authorize(
        _principal,
        "initialize",
        %OzMcp.Pipeline.Bound{params: %{"clientInfo" => %{"name" => "refused-client"}}}
      ),
      do: {:error, {:insufficient_scope, ["files:admin"]}}

  def authorize(
        _principal,
        "initialize",
        %OzMcp.Pipeline.Bound{params: %{"clientInfo" => %{"name" => "crash-client"}}}
      ),
      do: raise("authorize failure")

  # Markers whose failure embeds the string "SECRET-TOKEN": the tests
  # use the marker to check that the framework writes no data of the
  # application to the log at level `:error`.
  #
  def authorize(_principal, "tasks/list", %OzMcp.Pipeline.Bound{
        params: %{"cursor" => "secret-match"}
      }),
      do: raise(MatchError, term: {:error, {:bad, "SECRET-TOKEN"}})

  def authorize(_principal, "tasks/list", %OzMcp.Pipeline.Bound{
        params: %{"cursor" => "secret-clause"}
      }),
      do: leak_clause("SECRET-TOKEN", 1)

  def authorize(_principal, "tasks/list", %OzMcp.Pipeline.Bound{
        params: %{"cursor" => "secret-throw"}
      }),
      do: throw({:bad, "SECRET-TOKEN"})

  def authorize(_principal, "tasks/list", %OzMcp.Pipeline.Bound{
        params: %{"cursor" => "secret-exit"}
      }),
      do: exit({:timeout, {GenServer, :call, [self(), {:verify, "SECRET-TOKEN"}, 5000]}})

  def authorize(_principal, "tasks/list", %OzMcp.Pipeline.Bound{
        params: %{"cursor" => "secret-value"}
      }),
      do: {:error, {:bad, "SECRET-TOKEN"}}

  def authorize(_principal, "tasks/list", %OzMcp.Pipeline.Bound{
        params: %{"cursor" => "secret-error-binary"}
      }),
      do: {:error, "SECRET-TOKEN"}

  # A value that collides with the failure marker of the framework.
  #
  def authorize(_principal, "tasks/list", %OzMcp.Pipeline.Bound{
        params: %{"cursor" => "failed-marker"}
      }),
      do: :failed

  # An empty scope list: the header must name the challenge_scopes of the
  # server.
  #
  def authorize(_principal, "tasks/list", %OzMcp.Pipeline.Bound{
        params: %{"cursor" => "empty-scopes"}
      }),
      do: {:error, {:insufficient_scope, []}}

  def authorize(_principal, "tasks/list", %OzMcp.Pipeline.Bound{
        params: %{"cursor" => "empty-scopes-description"}
      }),
      do: {:error, {:insufficient_scope, [], "need more scopes"}}

  def authorize(
        _principal,
        "initialize",
        %OzMcp.Pipeline.Bound{params: %{"clientInfo" => %{"name" => "empty-scope-client"}}}
      ),
      do: {:error, {:insufficient_scope, []}}

  def authorize(_principal, _method, _bound), do: :ok

  # The bound entity of the last task-augmented call of the principal
  # whose subject is `subject`.
  #
  def task_bound(subject), do: :persistent_term.get({__MODULE__, :task_bound, subject}, nil)

  # A clause that never matches: the raise of the failure carries the
  # arguments and with them the marker string.
  #
  defp leak_clause(_token, _count) when false, do: :ok
end
