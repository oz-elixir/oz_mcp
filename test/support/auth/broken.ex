#
# A verifier whose behaviour the token selects. Each broken token shows
# one defect an application can have: a raise, a throw, an exit, a bad
# return value, a shortcut atom the contract does not know, or a
# challenge whose error the contract does not know. The framework must
# answer a server error for each of them and never authenticate the
# caller.
#
# The tokens with "secret" in their name embed the marker string
# "SECRET-TOKEN" in the data of the failure: the tests use the marker
# to check that the framework writes no data of the application to the
# log at level `:error`.
#
defmodule Support.Auth.Broken do
  @behaviour OzMcp.Auth

  alias OzMcp.Auth.Challenge
  alias OzMcp.Auth.Principal

  @impl true
  def authenticate(conn, _server) do
    case OzMcp.Auth.bearer_token(conn) do
      {:ok, "raise-token"} ->
        raise "verifier failure"

      {:ok, "throw-token"} ->
        throw(:verifier_failure)

      {:ok, "exit-token"} ->
        exit(:verifier_failure)

      {:ok, "bad-value-token"} ->
        {:ok, "not a principal"}

      # A principal whose subject is not a non-empty string: the log of
      # the invalid value names the defect and holds no other field.
      #
      {:ok, "nil-subject-token"} ->
        {:ok, %Principal{subject: nil, claims: %{"name" => "SECRET-TOKEN"}}}

      # A principal whose audiences are not a list of strings: the
      # audience compare of the gate fails closed.
      #
      {:ok, "bad-audiences-token"} ->
        {:ok, %Principal{subject: "broken", audiences: "https://other.example.com/mcp"}}

      # A tuple whose second element is an integer: the log names the
      # type of the element.
      #
      {:ok, "integer-error-token"} ->
        {:error, 401}

      {:ok, "unknown-atom-token"} ->
        {:error, :not_a_challenge}

      # A challenge whose error is not one of the errors of the contract.
      #
      {:ok, "bogus-challenge-token"} ->
        {:error, %Challenge{error: :bogus}}

      # A challenge whose description is not a string or nil.
      #
      {:ok, "bad-description-token"} ->
        {:error, %Challenge{error: :invalid_token, description: 123}}

      # A challenge whose scopes are not a list of scope tokens.
      #
      {:ok, "bad-scopes-token"} ->
        {:error, %Challenge{error: :insufficient_scope, scopes: "abc"}}

      # A description that the constructor refuses: the raise happens
      # inside authenticate/2 and the Guard answers for it.
      #
      {:ok, "bad-constructor-token"} ->
        {:error, Challenge.invalid_token(123)}

      # A MatchError: the text of the exception holds the marker string.
      #
      {:ok, "match-token"} ->
        raise MatchError, term: {:error, {:bad, "SECRET-TOKEN"}}

      # A FunctionClauseError: the top frame of the stacktrace holds the
      # arguments and with them the marker string.
      #
      {:ok, "clause-token"} ->
        leak_clause("SECRET-TOKEN", 1)

      {:ok, "throw-secret-token"} ->
        throw({:bad, "SECRET-TOKEN"})

      {:ok, "exit-secret-token"} ->
        exit({:timeout, {GenServer, :call, [self(), {:verify, "SECRET-TOKEN"}, 5000]}})

      {:ok, "value-secret-token"} ->
        {:error, {:bad, "SECRET-TOKEN"}}

      # A value that collides with the failure marker of the framework.
      #
      {:ok, "failed-marker-token"} ->
        :failed

      {:ok, _token} ->
        {:ok, Principal.new!(subject: "broken", audiences: ["https://mcp.example.com/mcp"])}

      error ->
        error
    end
  end

  # A clause that never matches: the raise of the failure carries the
  # arguments and with them the marker string.
  #
  defp leak_clause(_token, _count) when false, do: :ok
end
