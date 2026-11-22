defmodule OzMcp.Auth.GateTest do
  #
  # Sync: the tests set flags in :persistent_term and change the state of the Support.Auth.Default verifier.
  #
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OzMcp.Auth.{Challenge, Gate, Principal}
  alias OzMcp.Context.Error
  alias Support.Helpers.Utils
  alias Support.Servers

  # The instance that serves a server module in this file.
  #
  defp inst(module), do: Module.concat(module, __MODULE__)

  @resource_url "https://mcp.example.com/mcp"
  @metadata_url "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"

  setup do
    Support.Auth.Default.reset()

    Utils.start_instances(
      [
        Servers.Default,
        {Servers.Authorized, %{resource_url: @resource_url}},
        {Servers.AuthorizedBroken, %{resource_url: @resource_url}}
      ],
      __MODULE__,
      allowed_origins: []
    )

    :ok
  end

  defp bearer_conn(token),
    do: conn(:get, "/") |> put_req_header("authorization", "Bearer #{token}")

  describe "config/1" do
    test "returns the authorization map of a server with the block" do
      auth = Gate.config(inst(Servers.Authorized))

      assert auth.verifier == Support.Auth.Default
      assert auth.challenge_scopes == ["files:read"]
    end

    test "returns nil for a server without the block" do
      assert Gate.config(inst(Servers.Default)) == nil
    end

    test "returns nil for a hand-written server module" do
      assert Gate.config(inst(Servers.Failing)) == nil
    end

    test "returns nil for a module that is not loaded" do
      assert Gate.config(NoSuchServerModule) == nil
    end
  end

  describe "fetch_config/1" do
    test "tells an open server from a protected server" do
      assert Gate.fetch_config(inst(Servers.Default)) == {:ok, nil}
      assert {:ok, %{verifier: _}} = Gate.fetch_config(inst(Servers.Authorized))
    end

    test "answers :not_running for an instance that does not run" do
      assert Gate.fetch_config(NoSuchServerModule) == :not_running
    end
  end

  describe "header/3" do
    test "uses the challenge_scopes of the server when the challenge has none" do
      assert Gate.header(
               Challenge.insufficient_scope([]),
               inst(Servers.Authorized),
               @metadata_url
             ) ==
               ~s(Bearer error="insufficient_scope", scope="files:read", resource_metadata="#{@metadata_url}")
    end

    test "keeps the scopes of the challenge when it has some" do
      header =
        Gate.header(
          Challenge.insufficient_scope(["files:write"]),
          inst(Servers.Authorized),
          @metadata_url
        )

      assert header =~ ~s(scope="files:write")
      refute header =~ "files:read"
    end

    test "gives no scope parameter when the server has no challenge_scopes" do
      Utils.start_instances(
        [{Servers.AuthorizedLocalhost, %{resource_url: @resource_url}}],
        __MODULE__,
        allowed_origins: []
      )

      assert Gate.header(
               Challenge.insufficient_scope([]),
               inst(Servers.AuthorizedLocalhost),
               @metadata_url
             ) ==
               ~s(Bearer error="insufficient_scope", resource_metadata="#{@metadata_url}")
    end
  end

  describe "run/2" do
    test "is disabled for a server without the block" do
      assert Gate.run(bearer_conn("alice-token"), inst(Servers.Default)) == :disabled
      assert Gate.run(conn(:get, "/"), inst(Servers.Default)) == :disabled
    end

    test "returns the principal of a valid token" do
      assert {:ok, %Principal{} = principal} =
               Gate.run(bearer_conn("alice-token"), inst(Servers.Authorized))

      assert principal.subject == "alice"
      assert principal.scopes == ["files:read"]
    end

    test "refuses a request with no token" do
      assert {:refuse, %Challenge{} = challenge, @metadata_url} =
               Gate.run(conn(:get, "/"), inst(Servers.Authorized))

      assert challenge.error == nil
    end

    test "refuses an unknown token" do
      assert {:refuse, %Challenge{error: :invalid_token}, @metadata_url} =
               Gate.run(bearer_conn("no-such-token"), inst(Servers.Authorized))
    end

    test "gives the token limit of the server to the verifier" do
      Utils.stop_instances()

      Utils.start_instances(
        [
          {Servers.Authorized, %{resource_url: @resource_url, max_token_bytes: 10}}
        ],
        __MODULE__,
        allowed_origins: []
      )

      assert {:refuse, %Challenge{error: :invalid_request, description: "token too long"},
              @metadata_url} =
               Gate.run(bearer_conn(String.duplicate("a", 11)), inst(Servers.Authorized))
    end

    test "a verifier that reads the header by hand is not limited" do
      start_hand_read_runtime(max_token_bytes: 10)
      conn = bearer_conn(String.duplicate("a", 500))

      assert {:ok, %Principal{subject: "hand-read"}} =
               Gate.run(conn, inst(Servers.AuthorizedHandRead))
    end

    defp start_hand_read_runtime(opts) do
      Utils.stop_instances()

      Utils.start_instances(
        [
          {Servers.AuthorizedHandRead, Map.merge(%{resource_url: @resource_url}, Map.new(opts))}
        ],
        __MODULE__,
        allowed_origins: []
      )
    end

    test "answers :not_running when the runtime does not have the server" do
      #
      # The module has the block, but the runtime did not start it.
      #
      assert Gate.run(bearer_conn("alice-token"), Servers.AuthorizedLocalhost) ==
               :not_running
    end

    test "fails closed when the verifier returns a value that is not a principal" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Gate.run(bearer_conn("bad-value-token"), inst(Servers.AuthorizedBroken)) ==
                   :error
        end)

      assert log =~ "returned an invalid value"
    end

    test "fails closed when the verifier raises, throws, or exits" do
      for token <- ["raise-token", "throw-token", "exit-token"] do
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert Gate.run(bearer_conn(token), inst(Servers.AuthorizedBroken)) == :error
          end)

        assert log =~ "authenticate/2 failed"
      end
    end

    test "fails closed on a shortcut atom the contract does not know" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Gate.run(
                   bearer_conn("unknown-atom-token"),
                   inst(Servers.AuthorizedBroken)
                 ) ==
                   :error
        end)

      assert log =~ "returned an invalid value"
      assert log =~ ":not_a_challenge"
    end

    test "fails closed on a challenge with an unknown error" do
      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          assert Gate.run(
                   bearer_conn("bogus-challenge-token"),
                   inst(Servers.AuthorizedBroken)
                 ) ==
                   :error
        end)

      assert log =~ "returned an invalid value"
      assert log =~ "unknown error: :bogus"
    end

    # Each token embeds the marker string "SECRET-TOKEN" in the data of
    # the failure: a raise, a throw, an exit, or a returned value.
    #
    for token <- [
          "match-token",
          "clause-token",
          "throw-secret-token",
          "exit-secret-token",
          "value-secret-token"
        ] do
      test "the log at level :error does not hold the marker string (#{token})" do
        log =
          Utils.capture_log([level: :error], fn ->
            assert Gate.run(bearer_conn(unquote(token)), inst(Servers.AuthorizedBroken)) ==
                     :error
          end)

        refute log =~ "SECRET-TOKEN"
        assert log =~ "authenticate/2"

        assert log |> String.split("\n") |> Enum.count(&String.contains?(&1, "[error]")) == 1
      end
    end

    test "a raise logs the exception module and a stacktrace with no arguments" do
      log =
        Utils.capture_log([level: :error], fn ->
          assert Gate.run(bearer_conn("clause-token"), inst(Servers.AuthorizedBroken)) ==
                   :error
        end)

      assert log =~ "FunctionClauseError"
      assert log =~ "leak_clause/2"
      refute log =~ "SECRET-TOKEN"
    end

    test "the text of the exception appears only at level :debug" do
      error_log =
        Utils.capture_log([level: :error], fn ->
          assert Gate.run(bearer_conn("match-token"), inst(Servers.AuthorizedBroken)) ==
                   :error
        end)

      refute error_log =~ "no match of right hand side"

      debug_log =
        Utils.capture_log([level: :debug], fn ->
          assert Gate.run(bearer_conn("match-token"), inst(Servers.AuthorizedBroken)) ==
                   :error
        end)

      assert debug_log =~ "no match of right hand side"
    end

    test "a verifier that returns :failed is an invalid value, not a failure" do
      log =
        Utils.capture_log(fn ->
          assert Gate.run(
                   bearer_conn("failed-marker-token"),
                   inst(Servers.AuthorizedBroken)
                 ) ==
                   :error
        end)

      assert log =~ "returned an invalid value: :failed"
      refute log =~ "authenticate/2 failed"
    end

    test "a principal with an empty subject is named in the log, with no other field" do
      log =
        Utils.capture_log([level: :error], fn ->
          assert Gate.run(
                   bearer_conn("nil-subject-token"),
                   inst(Servers.AuthorizedBroken)
                 ) ==
                   :error
        end)

      assert log =~ "authenticate/2 returned an invalid value"
      assert log =~ "principal with an empty or non-binary subject"
      refute log =~ "SECRET-TOKEN"
    end

    test "the second element of a returned tuple is named by its type" do
      log =
        Utils.capture_log([level: :error], fn ->
          assert Gate.run(
                   bearer_conn("integer-error-token"),
                   inst(Servers.AuthorizedBroken)
                 ) ==
                   :error
        end)

      assert log =~ "authenticate/2 returned an invalid value"
      assert log =~ "second element: integer"
      refute log =~ "SECRET-TOKEN"
    end

    test "fails closed on a challenge with a description that is not a string" do
      log =
        Utils.capture_log([level: :error], fn ->
          assert Gate.run(
                   bearer_conn("bad-description-token"),
                   inst(Servers.AuthorizedBroken)
                 ) ==
                   :error
        end)

      assert log =~ "authenticate/2 returned an invalid value"
      assert log =~ "a description that is not a string or nil"
      refute log =~ "SECRET-TOKEN"
    end

    test "fails closed on a challenge with scopes that are not a list" do
      log =
        Utils.capture_log([level: :error], fn ->
          assert Gate.run(
                   bearer_conn("bad-scopes-token"),
                   inst(Servers.AuthorizedBroken)
                 ) ==
                   :error
        end)

      assert log =~ "authenticate/2 returned an invalid value"
      assert log =~ "with scopes that are not a list"
      refute log =~ "SECRET-TOKEN"
    end

    test "a raise of the challenge constructor inside the verifier names the field at :debug" do
      error_log =
        Utils.capture_log([level: :error], fn ->
          assert Gate.run(
                   bearer_conn("bad-constructor-token"),
                   inst(Servers.AuthorizedBroken)
                 ) ==
                   :error
        end)

      assert error_log =~ "authenticate/2 failed"
      assert error_log =~ "raised ArgumentError"
      refute error_log =~ "invalid_token/1 expects"

      debug_log =
        Utils.capture_log([level: :debug], fn ->
          assert Gate.run(
                   bearer_conn("bad-constructor-token"),
                   inst(Servers.AuthorizedBroken)
                 ) ==
                   :error
        end)

      assert debug_log =~ "invalid_token/1 expects a string or nil as description"
    end

    test "a principal that is expired is refused with invalid_token" do
      Support.Auth.Default.expire_at("alice-token", System.system_time(:second) - 10)
      on_exit(fn -> Support.Auth.Default.reset() end)

      assert {:refuse, %Challenge{error: :invalid_token, description: "token expired"},
              @metadata_url} =
               Gate.run(bearer_conn("alice-token"), inst(Servers.Authorized))
    end

    test "a principal with no expiry passes" do
      assert {:ok, %Principal{subject: "alice"}} =
               Gate.run(bearer_conn("alice-token"), inst(Servers.Authorized))
    end

    test "a principal that expires in the future passes" do
      Support.Auth.Default.expire_at("alice-token", System.system_time(:second) + 60)
      on_exit(fn -> Support.Auth.Default.reset() end)

      assert {:ok, %Principal{subject: "alice"}} =
               Gate.run(bearer_conn("alice-token"), inst(Servers.Authorized))
    end

    test "a principal with a huge expiry passes" do
      Support.Auth.Default.expire_at("alice-token", 1.0e308)
      on_exit(fn -> Support.Auth.Default.reset() end)

      assert {:ok, %Principal{subject: "alice"}} =
               Gate.run(bearer_conn("alice-token"), inst(Servers.Authorized))
    end
  end

  describe "run/2 and the audience of the token" do
    test "a principal with the audience of the resource URL passes" do
      assert {:ok, %Principal{subject: "alice"}} =
               Gate.run(bearer_conn("alice-token"), inst(Servers.Authorized))
    end

    test "the compare of the audience ignores the case of the scheme and the host" do
      assert {:ok, %Principal{subject: "alice"}} =
               Gate.run(bearer_conn("upper-audience"), inst(Servers.Authorized))
    end

    test "a principal for another audience is refused with invalid_token" do
      assert {:refuse, %Challenge{error: :invalid_token, description: "token audience mismatch"},
              @metadata_url} =
               Gate.run(bearer_conn("other-audience"), inst(Servers.Authorized))
    end

    test "a principal without audiences is refused and the warning is written once per server" do
      flag = {OzMcp.Auth.Gate, inst(Servers.Authorized), :missing_audiences}
      :persistent_term.erase(flag)
      on_exit(fn -> :persistent_term.erase(flag) end)

      log =
        Utils.capture_log([level: :warning], fn ->
          for _ <- 1..2 do
            assert {:refuse,
                    %Challenge{error: :invalid_token, description: "token audience mismatch"},
                    @metadata_url} =
                     Gate.run(bearer_conn("no-audience"), inst(Servers.Authorized))
          end
        end)

      assert log =~ "returned a principal without audiences"
      assert log =~ "Set :audiences, or set audience_check false"
      assert log |> String.split("\n") |> Enum.count(&String.contains?(&1, "[warning]")) == 1
    end

    test "a server with audience_check false accepts another audience and no audience" do
      Utils.stop_instances()

      Utils.start_instances(
        [{Servers.AuthorizedLocalhost, %{resource_url: @resource_url}}],
        __MODULE__,
        allowed_origins: []
      )

      assert {:ok, %Principal{subject: "alice"}} =
               Gate.run(bearer_conn("other-audience"), inst(Servers.AuthorizedLocalhost))

      assert {:ok, %Principal{subject: "alice"}} =
               Gate.run(bearer_conn("no-audience"), inst(Servers.AuthorizedLocalhost))
    end

    test "an expired principal without audiences gets token expired, not the audience error" do
      Support.Auth.Default.expire_at("no-audience", System.system_time(:second) - 10)
      on_exit(fn -> Support.Auth.Default.reset() end)

      assert {:refuse, %Challenge{error: :invalid_token, description: "token expired"},
              @metadata_url} =
               Gate.run(bearer_conn("no-audience"), inst(Servers.Authorized))
    end

    test "a principal whose audiences are not a list is refused (fail closed)" do
      assert {:refuse, %Challenge{error: :invalid_token, description: "token audience mismatch"},
              @metadata_url} =
               Gate.run(
                 bearer_conn("bad-audiences-token"),
                 inst(Servers.AuthorizedBroken)
               )
    end
  end

  # The router picks the error code of a refusal from the challenge and
  # the table of the errors fixes the status. Both must agree with the
  # status of the protocol of each challenge, or a refusal would go out
  # with the wrong HTTP status.
  #
  describe "challenge status and error table" do
    test "agree for every challenge shape" do
      pairs = [
        {Challenge.missing_token(), 401},
        {Challenge.invalid_token(), 401},
        {Challenge.invalid_request(), 400},
        {Challenge.insufficient_scope(["files:read"]), 403}
      ]

      for {challenge, expected} <- pairs do
        {status, _body} = Error.build(Error.new(Challenge.error_code(challenge)), nil)
        assert status == expected
      end
    end
  end
end
