defmodule OzMcp.Auth.ChallengeTest do
  use ExUnit.Case, async: true

  alias OzMcp.Auth.Challenge

  @metadata "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"

  describe "constructors" do
    test "missing_token/0 has no error, no description and no scopes" do
      assert Challenge.missing_token() == %Challenge{error: nil, description: nil, scopes: []}
    end

    test "invalid_token/1 defaults the description to nil" do
      assert Challenge.invalid_token() == %Challenge{
               error: :invalid_token,
               description: nil,
               scopes: []
             }

      assert Challenge.invalid_token("token expired") ==
               %Challenge{error: :invalid_token, description: "token expired", scopes: []}
    end

    test "invalid_request/1 defaults the description to nil" do
      assert Challenge.invalid_request() == %Challenge{
               error: :invalid_request,
               description: nil,
               scopes: []
             }
    end

    test "insufficient_scope/2 holds the scopes" do
      challenge = Challenge.insufficient_scope(["files:read", "files:write"], "write needed")

      assert challenge.error == :insufficient_scope
      assert challenge.scopes == ["files:read", "files:write"]
      assert challenge.description == "write needed"
    end
  end

  describe "from/1" do
    test "passes a challenge through" do
      challenge = Challenge.invalid_token("nope")

      assert Challenge.from(challenge) == challenge
    end

    test "turns the shortcut atoms into challenges" do
      assert Challenge.from(:missing_token) == Challenge.missing_token()
      assert Challenge.from(:invalid_token) == Challenge.invalid_token()
      assert Challenge.from(:invalid_request) == Challenge.invalid_request()
    end

    test "raises a clear error for an unknown atom" do
      reason = String.to_atom("nope")

      assert_raise ArgumentError,
                   "authenticate/2 returned the shortcut atom :nope, " <>
                     "but only :missing_token, :invalid_token and :invalid_request are challenges",
                   fn -> Challenge.from(reason) end
    end

    test "raises for a challenge with an unknown error atom" do
      assert_raise ArgumentError,
                   "authenticate/2 returned a challenge with an unknown error: :bogus",
                   fn -> Challenge.from(%Challenge{error: :bogus}) end
    end

    test "raises for a challenge whose error is not an atom" do
      assert_raise ArgumentError,
                   "authenticate/2 returned a challenge with an unknown error: not an atom",
                   fn -> Challenge.from(%Challenge{error: "x"}) end
    end
  end

  describe "from/1 checks description and scopes" do
    test "raises for a description that is not a string" do
      assert_raise ArgumentError,
                   "authenticate/2 returned a challenge with a description that is not a string or nil",
                   fn -> Challenge.from(%Challenge{error: :invalid_token, description: 123}) end
    end

    test "raises for scopes that are not a list" do
      assert_raise ArgumentError, ~r/with scopes that are not a list/, fn ->
        Challenge.from(%Challenge{error: :insufficient_scope, scopes: "abc"})
      end
    end

    test "raises for a scope that is not a scope token and for an improper list" do
      for scopes <- [["a b"], [123], ["a" | "b"]] do
        assert_raise ArgumentError, fn ->
          Challenge.from(%Challenge{error: :insufficient_scope, scopes: scopes})
        end
      end
    end

    test "the message never holds the value" do
      error =
        assert_raise ArgumentError, fn ->
          Challenge.from(%Challenge{error: :invalid_token, description: {:bad, "SECRET-TOKEN"}})
        end

      refute error.message =~ "SECRET-TOKEN"
    end
  end

  describe "constructors check the description" do
    test "invalid_token/1, invalid_request/1 and insufficient_scope/2 raise for 123" do
      assert_raise ArgumentError, fn -> Challenge.invalid_token(123) end
      assert_raise ArgumentError, fn -> Challenge.invalid_request(123) end
      assert_raise ArgumentError, fn -> Challenge.insufficient_scope(["a"], 123) end
    end

    test "insufficient_scope/2 raises for scopes that are not a list" do
      assert_raise ArgumentError, fn -> Challenge.insufficient_scope("abc") end
    end

    test "a nil description and an empty string are valid" do
      assert %Challenge{description: nil} = Challenge.invalid_token(nil)
      assert %Challenge{description: ""} = Challenge.invalid_token("")
    end
  end

  describe "insufficient_scope/2 scope validation" do
    test "accepts every scope-token character of RFC 6749" do
      scope = List.to_string(for c <- 0x21..0x7E, c not in [0x22, 0x5C], do: c)

      assert %Challenge{scopes: [^scope]} = Challenge.insufficient_scope([scope])
    end

    test "raises for a scope with a space" do
      assert_raise ArgumentError, fn -> Challenge.insufficient_scope(["files read"]) end
    end

    test "raises for a scope with a double quote" do
      assert_raise ArgumentError, fn -> Challenge.insufficient_scope(["files\"read"]) end
    end

    test "raises for a scope with a backslash" do
      assert_raise ArgumentError, fn -> Challenge.insufficient_scope(["files\\read"]) end
    end

    test "raises for a non-ascii scope" do
      assert_raise ArgumentError, fn -> Challenge.insufficient_scope(["café"]) end
    end

    test "raises for a non-string scope" do
      assert_raise ArgumentError, fn -> Challenge.insufficient_scope([:files_read]) end
    end
  end

  describe "header/3" do
    test "holds only the metadata url for a missing token" do
      header = Challenge.header(Challenge.missing_token(), @metadata)

      assert header == ~s(Bearer resource_metadata="#{@metadata}")
    end

    test "holds no parameter at all without a metadata url" do
      assert Challenge.header(Challenge.missing_token(), nil) == "Bearer"
    end

    test "never holds an error parameter for a missing token" do
      header = Challenge.header(Challenge.missing_token(), @metadata, ["files:read"])

      assert header == ~s(Bearer scope="files:read", resource_metadata="#{@metadata}")
    end

    test "holds the error and the description for an invalid token" do
      header = Challenge.header(Challenge.invalid_token("token expired"), @metadata)

      assert header ==
               ~s(Bearer error="invalid_token", error_description="token expired", resource_metadata="#{@metadata}")
    end

    test "holds the error for an invalid request" do
      header = Challenge.header(Challenge.invalid_request(), @metadata)

      assert header == ~s(Bearer error="invalid_request", resource_metadata="#{@metadata}")
    end

    test "holds the scopes of an insufficient scope challenge" do
      challenge = Challenge.insufficient_scope(["files:read", "files:write"])

      header = Challenge.header(challenge, @metadata)

      assert header ==
               ~s(Bearer error="insufficient_scope", scope="files:read files:write", resource_metadata="#{@metadata}")
    end

    test "uses the default scopes when the challenge holds none" do
      header = Challenge.header(Challenge.invalid_token("old"), @metadata, ["files:read"])

      assert header ==
               ~s(Bearer error="invalid_token", error_description="old", scope="files:read", resource_metadata="#{@metadata}")
    end

    test "prefers the scopes of the challenge over the default scopes" do
      challenge = Challenge.insufficient_scope(["files:write"])

      header = Challenge.header(challenge, @metadata, ["files:read"])

      assert header ==
               ~s(Bearer error="insufficient_scope", scope="files:write", resource_metadata="#{@metadata}")
    end

    test "replaces a double quote in the description with a question mark" do
      header = Challenge.header(Challenge.invalid_request("a \"quoted\" word"), nil)

      assert header == "Bearer error=\"invalid_request\", error_description=\"a ?quoted? word\""
    end

    test "replaces a backslash in the description with a question mark" do
      header = Challenge.header(Challenge.invalid_request("a back\\slash"), nil)

      assert header == "Bearer error=\"invalid_request\", error_description=\"a back?slash\""
    end

    test "replaces a newline, a carriage return and a control byte with a question mark" do
      description = "line1\nline2\r" <> <<0>>

      header = Challenge.header(Challenge.invalid_token(description), nil)

      assert header == "Bearer error=\"invalid_token\", error_description=\"line1?line2??\""
      refute String.contains?(header, "\n")
      refute String.contains?(header, "\r")
    end

    test "replaces a non-ascii character with one question mark" do
      header = Challenge.header(Challenge.invalid_token("café"), nil)

      assert header == "Bearer error=\"invalid_token\", error_description=\"caf?\""
    end

    test "replaces an invalid byte without raising" do
      header = Challenge.header(Challenge.invalid_token(<<"a", 0xFF, "b">>), nil)

      assert header == "Bearer error=\"invalid_token\", error_description=\"a?b\""
    end

    test "a description of 250 non-ascii characters gives 200 question marks" do
      header = Challenge.header(Challenge.invalid_request(String.duplicate("é", 250)), nil)

      assert header ==
               "Bearer error=\"invalid_request\", error_description=\"#{String.duplicate("?", 200)}\""
    end

    test "a hand-built scope with a double quote cannot break the header" do
      challenge = %Challenge{error: :insufficient_scope, scopes: ["a\"b"]}

      header = Challenge.header(challenge, nil)

      assert header == ~s(Bearer error="insufficient_scope", scope="a?b")

      scope = param_value(header, "scope")
      refute String.contains?(scope, "\"")
      refute String.contains?(scope, "\\")
    end

    test "a metadata url with a double quote cannot break the header" do
      header = Challenge.header(Challenge.missing_token(), "https://mcp.example.com/a\"b")

      assert header == ~s(Bearer resource_metadata="https://mcp.example.com/a?b")

      url = param_value(header, "resource_metadata")
      refute String.contains?(url, "\"")
      refute String.contains?(url, "\\")
    end

    test "cuts a long description" do
      header = Challenge.header(Challenge.invalid_request(String.duplicate("a", 250)), nil)

      assert header ==
               "Bearer error=\"invalid_request\", error_description=\"#{String.duplicate("a", 200)}\""
    end
  end

  describe "error_code/1" do
    test "answers :http_unauthorized for a missing token" do
      assert Challenge.error_code(Challenge.missing_token()) == :http_unauthorized
    end

    test "answers :http_unauthorized for an invalid token" do
      assert Challenge.error_code(Challenge.invalid_token("expired")) == :http_unauthorized
    end

    test "answers :http_bad_authorization for an invalid request" do
      assert Challenge.error_code(Challenge.invalid_request("bad syntax")) ==
               :http_bad_authorization
    end

    test "answers :http_insufficient_scope for an insufficient scope" do
      assert Challenge.error_code(Challenge.insufficient_scope(["files:read"])) ==
               :http_insufficient_scope
    end
  end

  defp param_value(header, key) do
    header
    |> String.split(~s(#{key}="), parts: 2)
    |> Enum.at(1)
    |> String.split("\"", parts: 2)
    |> Enum.at(0)
  end
end
