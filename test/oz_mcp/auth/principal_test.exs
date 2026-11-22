defmodule OzMcp.Auth.PrincipalTest do
  use ExUnit.Case, async: true

  alias OzMcp.Auth.Principal

  describe "new!/1" do
    test "builds a principal from keyword attributes" do
      principal =
        Principal.new!(
          issuer: "https://issuer.test",
          subject: "alice",
          client_id: "client-1",
          scopes: ["files:read"],
          claims: %{"role" => "dev"},
          expires_at: 1_760_000_000
        )

      assert %Principal{} = principal
      assert principal.issuer == "https://issuer.test"
      assert principal.subject == "alice"
      assert principal.client_id == "client-1"
      assert principal.scopes == ["files:read"]
      assert principal.claims == %{"role" => "dev"}
      assert principal.expires_at == 1_760_000_000
    end

    test "builds a principal from a map" do
      assert %Principal{subject: "bob"} = Principal.new!(%{subject: "bob"})
    end

    test "applies the defaults" do
      principal = Principal.new!(subject: "alice")

      assert principal.issuer == nil
      assert principal.client_id == nil
      assert principal.scopes == []
      assert principal.audiences == nil
      assert principal.claims == %{}
      assert principal.expires_at == nil
    end

    test "raises when the subject is missing" do
      assert_raise ArgumentError, ~r/subject/, fn -> Principal.new!([]) end
    end

    test "raises when the subject is empty" do
      assert_raise ArgumentError, "principal subject must be a non-empty string", fn ->
        Principal.new!(subject: "")
      end
    end

    test "raises when the subject is not a string" do
      assert_raise ArgumentError, "principal subject must be a non-empty string", fn ->
        Principal.new!(subject: 42)
      end
    end

    test "raises when the issuer is not a string or nil" do
      for issuer <- [:google, 42, ~c"charlist", %URI{host: "issuer.test"}] do
        assert_raise ArgumentError, "principal issuer must be a string or nil", fn ->
          Principal.new!(subject: "alice", issuer: issuer)
        end
      end
    end

    test "raises when a scope is not a string" do
      assert_raise ArgumentError, "principal scopes must be a list of strings", fn ->
        Principal.new!(subject: "alice", scopes: [:files_read])
      end
    end

    test "raises when the scopes are not a list" do
      assert_raise ArgumentError, "principal scopes must be a list of strings", fn ->
        Principal.new!(subject: "alice", scopes: "files:read")
      end
    end

    test "raises for an unknown attribute" do
      assert_raise KeyError, ~r/:bogus/, fn ->
        Principal.new!(subject: "alice", bogus: true)
      end
    end
  end

  describe "expires_at" do
    test "new!/1 accepts an integer, a float and nil" do
      assert Principal.new!(subject: "a", expires_at: 1_760_000_000).expires_at == 1_760_000_000

      assert Principal.new!(subject: "a", expires_at: 1_760_000_000.5).expires_at ==
               1_760_000_000.5

      assert Principal.new!(subject: "a").expires_at == nil
    end

    test "new!/1 raises for a string and for an atom" do
      assert_raise ArgumentError, ~r/expires_at/, fn ->
        Principal.new!(subject: "a", expires_at: "1760000000")
      end

      assert_raise ArgumentError, ~r/expires_at/, fn ->
        Principal.new!(subject: "a", expires_at: :never)
      end
    end

    test "expires_in/2 is the distance in milliseconds" do
      principal = Principal.new!(subject: "a", expires_at: 100)

      assert Principal.expires_in(principal, 99_000) == 1_000
      assert Principal.expires_in(principal, 100_000) == 0
      assert Principal.expires_in(principal, 101_500) == -1_500
    end

    test "expires_in/2 is nil without an expiry and for a struct with a bad value" do
      assert Principal.expires_in(Principal.new!(subject: "a")) == nil
      assert Principal.expires_in(%Principal{subject: "a", expires_at: "x"}) == nil
    end

    test "expired?/2 is true at the instant and after it" do
      principal = Principal.new!(subject: "a", expires_at: 100)

      refute Principal.expired?(principal, 99_999)
      assert Principal.expired?(principal, 100_000)
      assert Principal.expired?(principal, 100_001)
      refute Principal.expired?(Principal.new!(subject: "a"), 100_001)
    end

    test "expires_in/2 does not raise for a huge number" do
      principal = Principal.new!(subject: "a", expires_at: 1.0e308)

      assert Principal.expires_in(principal, 100_000) > 0
      refute Principal.expired?(principal, 100_000)
    end

    test "expires_in/2 keeps the fraction of a float" do
      principal = Principal.new!(subject: "a", expires_at: 100.5)

      assert Principal.expires_in(principal, 100_000) == 500
      assert Principal.expired?(principal, 100_500)
    end

    test "a value in the year 3000 is a normal future time" do
      principal = Principal.new!(subject: "a", expires_at: 32_503_680_000)

      assert Principal.expires_in(principal, 100_000) == 32_503_680_000_000 - 100_000
    end
  end

  describe "audiences" do
    test "new!/1 accepts nil, one string and a list of strings" do
      assert Principal.new!(subject: "a", audiences: nil).audiences == nil

      assert Principal.new!(subject: "a", audiences: "https://mcp.test").audiences ==
               ["https://mcp.test"]

      assert Principal.new!(subject: "a", audiences: ["https://a.test", "https://b.test"]).audiences ==
               ["https://a.test", "https://b.test"]
    end

    test "new!/1 keeps an empty list" do
      assert Principal.new!(subject: "a", audiences: []).audiences == []
    end

    test "new!/1 raises for a number, an atom and a list with a value that is not a string" do
      message = "principal audiences must be a string, a list of strings or nil"

      for bad <- [42, :mcp, [42], [nil], ["a", 1]] do
        assert_raise ArgumentError, message, fn ->
          Principal.new!(subject: "a", audiences: bad)
        end
      end
    end
  end

  describe "key/1" do
    test "returns the issuer and the subject" do
      principal = Principal.new!(issuer: "https://issuer.test", subject: "alice")

      assert Principal.key(principal) == {"https://issuer.test", "alice"}
    end

    test "returns a nil issuer when the principal has none" do
      assert Principal.key(Principal.new!(subject: "alice")) == {nil, "alice"}
    end
  end

  describe "scope?/2" do
    test "accepts one needed scope" do
      principal = Principal.new!(subject: "alice", scopes: ["files:read", "files:write"])

      assert Principal.scope?(principal, "files:read")
      refute Principal.scope?(principal, "admin")
    end

    test "accepts a list of needed scopes" do
      principal = Principal.new!(subject: "alice", scopes: ["files:read", "files:write"])

      assert Principal.scope?(principal, ["files:read", "files:write"])
      refute Principal.scope?(principal, ["files:read", "admin"])
    end

    test "accepts an empty list of needed scopes" do
      principal = Principal.new!(subject: "alice", scopes: [])

      assert Principal.scope?(principal, [])
      refute Principal.scope?(principal, "files:read")
    end
  end
end
