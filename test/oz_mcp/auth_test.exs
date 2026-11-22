defmodule OzMcp.AuthTest do
  use ExUnit.Case, async: true

  alias OzMcp.Auth
  alias OzMcp.Auth.Challenge
  alias OzMcp.Auth.Principal

  defp conn(headers \\ []) do
    %Plug.Conn{req_headers: headers}
  end

  describe "bearer_token/1" do
    test "reads the token of a bearer authorization header" do
      assert {:ok, "abc123"} = Auth.bearer_token(conn([{"authorization", "Bearer abc123"}]))
    end

    test "accepts the bearer scheme written in any case" do
      assert {:ok, "abc123"} = Auth.bearer_token(conn([{"authorization", "bearer abc123"}]))
      assert {:ok, "abc123"} = Auth.bearer_token(conn([{"authorization", "BEARER abc123"}]))
    end

    test "accepts every token character of RFC 6750" do
      token = "aZ09-._~+/="

      assert {:ok, ^token} = Auth.bearer_token(conn([{"authorization", "Bearer " <> token}]))
    end

    test "accepts a token of exactly the size limit" do
      token = String.duplicate("a", 8192)

      assert {:ok, ^token} = Auth.bearer_token(conn([{"authorization", "Bearer " <> token}]))
    end

    test "answers missing_token when the header is absent" do
      assert {:error, %Challenge{error: nil, description: nil, scopes: []}} =
               Auth.bearer_token(conn())
    end

    test "answers missing_token for another scheme" do
      header = "Basic " <> Base.encode64("user:pass")

      assert {:error, %Challenge{error: nil}} =
               Auth.bearer_token(conn([{"authorization", header}]))
    end

    test "answers missing_token when the bearer scheme holds no token" do
      assert {:error, %Challenge{error: nil}} =
               Auth.bearer_token(conn([{"authorization", "Bearer"}]))
    end

    test "never reads a token from the query string" do
      conn = %Plug.Conn{query_string: "access_token=secret", req_headers: []}

      assert {:error, %Challenge{error: nil}} = Auth.bearer_token(conn)
    end

    test "answers invalid_request when two authorization headers are present" do
      headers = [{"authorization", "Bearer one"}, {"authorization", "Bearer two"}]

      assert {:error, %Challenge{error: :invalid_request}} = Auth.bearer_token(conn(headers))
    end

    test "answers missing_token when the bearer scheme holds a trailing space only" do
      assert {:error, %Challenge{error: nil, description: nil}} =
               Auth.bearer_token(conn([{"authorization", "Bearer "}]))
    end

    test "answers missing_token when the bearer scheme holds spaces only" do
      assert {:error, %Challenge{error: nil}} =
               Auth.bearer_token(conn([{"authorization", "Bearer   "}]))
    end

    test "skips all the spaces after the scheme" do
      assert {:ok, "abc"} = Auth.bearer_token(conn([{"authorization", "Bearer  abc"}]))
    end

    test "a tab after the spaces stays in the token and makes it malformed" do
      assert {:error, %Challenge{error: :invalid_request, description: "malformed token"}} =
               Auth.bearer_token(conn([{"authorization", "Bearer \tabc"}]))
    end

    test "answers invalid_request for a token with a space" do
      assert {:error, %Challenge{error: :invalid_request, description: "malformed token"}} =
               Auth.bearer_token(conn([{"authorization", "Bearer abc def"}]))
    end

    test "answers invalid_request for a token with forbidden characters" do
      assert {:error, %Challenge{error: :invalid_request}} =
               Auth.bearer_token(conn([{"authorization", "Bearer ab\"c"}]))

      assert {:error, %Challenge{error: :invalid_request}} =
               Auth.bearer_token(conn([{"authorization", "Bearer ab\\c"}]))
    end

    test "answers invalid_request for a token over the size limit" do
      token = String.duplicate("a", 8193)

      assert {:error, %Challenge{error: :invalid_request, description: "token too long"}} =
               Auth.bearer_token(conn([{"authorization", "Bearer " <> token}]))
    end

    test "the option max_bytes overrides the default limit" do
      token = String.duplicate("a", 9000)

      assert {:error, %Challenge{error: :invalid_request, description: "token too long"}} =
               Auth.bearer_token(conn([{"authorization", "Bearer " <> token}]))

      assert {:ok, ^token} =
               Auth.bearer_token(conn([{"authorization", "Bearer " <> token}]), max_bytes: 10_000)
    end

    test "reads the limit of the server from the connection" do
      token = String.duplicate("a", 101)

      conn = %Plug.Conn{
        req_headers: [{"authorization", "Bearer " <> token}],
        private: %{oz_mcp_max_token_bytes: 100}
      }

      assert {:error, %Challenge{error: :invalid_request, description: "token too long"}} =
               Auth.bearer_token(conn)
    end

    test "the option max_bytes wins over the limit of the connection" do
      token = String.duplicate("a", 150)

      conn = %Plug.Conn{
        req_headers: [{"authorization", "Bearer " <> token}],
        private: %{oz_mcp_max_token_bytes: 100}
      }

      assert {:ok, ^token} = Auth.bearer_token(conn, max_bytes: 200)
    end
  end

  describe "loopback_host?/1" do
    test "is true for the loopback hosts, in any case" do
      assert Auth.loopback_host?("localhost")
      assert Auth.loopback_host?("LOCALHOST")
      assert Auth.loopback_host?("127.0.0.1")
      assert Auth.loopback_host?("::1")
    end

    test "is false for any other host or value" do
      refute Auth.loopback_host?("example.com")
      refute Auth.loopback_host?("localhost.example.com")
      refute Auth.loopback_host?("127.0.0.2")
      refute Auth.loopback_host?(nil)
      refute Auth.loopback_host?(123)
    end
  end

  describe "behaviour contract" do
    test "authenticate/2 is a callback and authorize/3 is optional" do
      callbacks = Auth.behaviour_info(:callbacks)

      assert {:authenticate, 2} in callbacks
      assert {:authorize, 3} in callbacks
      assert Auth.behaviour_info(:optional_callbacks) == [authorize: 3]
    end
  end

  describe "Support.Auth.Default" do
    test "returns the principal of a known token" do
      assert {:ok, %Principal{} = principal} =
               Support.Auth.Default.authenticate(
                 conn([{"authorization", "Bearer alice-token"}]),
                 __MODULE__
               )

      assert principal.issuer == "https://issuer.test"
      assert principal.subject == "alice"
      assert principal.scopes == ["files:read"]
      assert principal.claims == %{}
      assert principal.client_id == nil
      assert principal.expires_at == nil
    end

    test "answers invalid_token for an unknown token" do
      assert {:error, %Challenge{error: :invalid_token, description: "unknown token"}} =
               Support.Auth.Default.authenticate(
                 conn([{"authorization", "Bearer nope"}]),
                 __MODULE__
               )
    end

    test "answers invalid_token for an expired token" do
      assert {:error, %Challenge{error: :invalid_token, description: "token expired"}} =
               Support.Auth.Default.authenticate(
                 conn([{"authorization", "Bearer expired-token"}]),
                 __MODULE__
               )
    end

    test "refuses a request without a usable token" do
      assert {:error, %Challenge{error: nil}} =
               Support.Auth.Default.authenticate(conn(), __MODULE__)
    end

    test "authorize/3 accepts a call in scope" do
      principal = Principal.new!(subject: "alice", scopes: ["files:read", "files:write"])
      bound = %OzMcp.Pipeline.Bound{kind: :tool, name: "get_date"}

      assert Support.Auth.Default.authorize(principal, "tools/call", bound) == :ok
    end

    test "authorize/3 refuses a call out of scope" do
      principal = Principal.new!(subject: "alice", scopes: ["files:read"])
      bound = %OzMcp.Pipeline.Bound{kind: :tool, name: "get_date"}

      assert Support.Auth.Default.authorize(principal, "tools/call", bound) ==
               {:error,
                {:insufficient_scope, ["files:read", "files:write"], "write permission needed"}}
    end

    test "authorize/3 accepts every other method" do
      principal = Principal.new!(subject: "alice", scopes: ["files:read"])
      none = %OzMcp.Pipeline.Bound{kind: :none}
      tool = %OzMcp.Pipeline.Bound{kind: :tool, name: "read_file"}

      assert Support.Auth.Default.authorize(principal, "tools/list", none) == :ok
      assert Support.Auth.Default.authorize(principal, "tools/call", tool) == :ok
    end
  end
end
