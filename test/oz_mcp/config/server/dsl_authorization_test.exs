#
# Tests for the `authorization/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLAuthorizationTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server
  alias Support.Servers

  describe "authorization/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a full authorization block and generates authorization/0" do
      server =
        module("AuthorizedFull") do
          authorization do
            verifier(Support.Auth.Default)
            authorization_servers(["https://auth.example.com"])
            scopes_supported(["files:read", "files:write"])
            challenge_scopes(["files:read"])
            resource_name("My App MCP server")
            resource_documentation("https://docs.example.com/mcp")
          end
        end
        |> compile()

      assert server.authorization() == %{
               verifier: Support.Auth.Default,
               authorization_servers: ["https://auth.example.com"],
               scopes_supported: ["files:read", "files:write"],
               challenge_scopes: ["files:read"],
               filter_by_scope: true,
               audience_check: true,
               resource_name: "My App MCP server",
               resource_documentation: "https://docs.example.com/mcp"
             }
    end

    test "accepts a minimal authorization block and applies the defaults" do
      server =
        module("AuthorizedMinimal") do
          authorization do
            verifier(Support.Auth.Default)
            authorization_servers(["https://auth.example.com"])
          end
        end
        |> compile()

      assert server.authorization() == %{
               verifier: Support.Auth.Default,
               authorization_servers: ["https://auth.example.com"],
               scopes_supported: nil,
               challenge_scopes: [],
               filter_by_scope: true,
               audience_check: true,
               resource_name: nil,
               resource_documentation: nil
             }
    end

    test "accepts http authorization servers on localhost only" do
      config =
        module("AuthorizedLocalhost") do
          authorization do
            verifier(Support.Auth.Default)

            authorization_servers([
              "https://auth.example.com",
              "http://localhost:8080",
              "http://127.0.0.1",
              "http://[::1]"
            ])
          end
        end
        |> compile_config()

      assert config.authorization.authorization_servers == [
               "https://auth.example.com",
               "http://localhost:8080",
               "http://127.0.0.1",
               "http://[::1]"
             ]
    end

    test "accepts empty scope lists" do
      config =
        module("AuthorizedEmptyScopes") do
          authorization do
            verifier(Support.Auth.Default)
            authorization_servers(["https://auth.example.com"])
            scopes_supported([])
            challenge_scopes([])
          end
        end
        |> compile_config()

      assert config.authorization.scopes_supported == []
      assert config.authorization.challenge_scopes == []
    end

    test "accepts filter_by_scope false" do
      config =
        module("AuthorizedFilterOff") do
          authorization do
            verifier(Support.Auth.Default)
            authorization_servers(["https://auth.example.com"])
            filter_by_scope(false)
          end
        end
        |> compile_config()

      assert config.authorization.filter_by_scope == false
    end

    test "accepts filter_by_scope true" do
      config =
        module("AuthorizedFilterOn") do
          authorization do
            verifier(Support.Auth.Default)
            authorization_servers(["https://auth.example.com"])
            filter_by_scope(true)
          end
        end
        |> compile_config()

      assert config.authorization.filter_by_scope == true
    end

    test "defaults audience_check to true" do
      config =
        module("AuthorizedAudienceDefault") do
          authorization do
            verifier(Support.Auth.Default)
            authorization_servers(["https://auth.example.com"])
          end
        end
        |> compile_config()

      assert config.authorization.audience_check == true
    end

    test "accepts audience_check false and true" do
      off =
        module("AuthorizedAudienceOff") do
          authorization do
            verifier(Support.Auth.Default)
            authorization_servers(["https://auth.example.com"])
            audience_check(false)
          end
        end
        |> compile_config()

      on =
        module("AuthorizedAudienceOn") do
          authorization do
            verifier(Support.Auth.Default)
            authorization_servers(["https://auth.example.com"])
            audience_check(true)
          end
        end
        |> compile_config()

      assert off.authorization.audience_check == false
      assert on.authorization.audience_check == true
    end

    test "authorization data is in config/0" do
      config = Servers.Authorized.config()

      assert config.authorization == %{
               verifier: Support.Auth.Default,
               authorization_servers: ["https://auth.example.com"],
               scopes_supported: ["files:read", "files:write"],
               challenge_scopes: ["files:read"],
               filter_by_scope: true,
               audience_check: true,
               resource_name: "Test MCP server",
               resource_documentation: "https://docs.example.com/mcp"
             }
    end

    test "a server with no authorization block returns nil" do
      assert Servers.Default.authorization() == nil
      assert Servers.Default.config().authorization == nil
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when verifier is missing" do
      module("AuthNoVerifier") do
        authorization do
          authorization_servers(["https://auth.example.com"])
        end
      end
      |> assert_compile_raise(ArgumentError, "'verifier' is required in the authorization block")
    end

    test "raises when verifier is a string instead of an atom" do
      module("AuthStringVerifier") do
        authorization do
          verifier("Support.Auth.Default")
          authorization_servers(["https://auth.example.com"])
        end
      end
      |> assert_compile_raise(ArgumentError, ~r"'verifier' must be a module \(atom\)")
    end

    test "raises when authorization_servers is missing" do
      module("AuthNoServers") do
        authorization do
          verifier(Support.Auth.Default)
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'authorization_servers' must be a non-empty list of URLs, got: []"
      )
    end

    test "raises when authorization_servers is empty" do
      module("AuthEmptyServers") do
        authorization do
          verifier(Support.Auth.Default)
          authorization_servers([])
        end
      end
      |> assert_compile_raise(ArgumentError, "'authorization_servers' cannot be an empty list")
    end

    test "raises when an authorization server is http off localhost" do
      module("AuthHttpServer") do
        authorization do
          verifier(Support.Auth.Default)
          authorization_servers(["http://auth.example.com"])
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~r"must be https URLs \(http is allowed only for a loopback host: localhost, 127\.0\.0\.1, ::1\).*http://auth\.example\.com"
      )
    end

    test "raises when an authorization server is not a URL" do
      module("AuthBadServer") do
        authorization do
          verifier(Support.Auth.Default)
          authorization_servers(["not a url"])
        end
      end
      |> assert_compile_raise(ArgumentError, ~r"must be https URLs.*not a url")
    end

    test "raises when a scope does not match the scope-token syntax" do
      module("AuthBadScope") do
        authorization do
          verifier(Support.Auth.Default)
          authorization_servers(["https://auth.example.com"])
          scopes_supported(["files:read", "files read"])
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~r"'scopes_supported' entries must match the RFC 6749 scope-token syntax"
      )
    end

    test "raises when a challenge scope does not match the scope-token syntax" do
      module("AuthBadChallengeScope") do
        authorization do
          verifier(Support.Auth.Default)
          authorization_servers(["https://auth.example.com"])
          challenge_scopes(["files\\read"])
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~r"'challenge_scopes' entries must match the RFC 6749 scope-token syntax"
      )
    end

    test "raises when resource_documentation is not an http(s) url" do
      module("AuthBadDocumentation") do
        authorization do
          verifier(Support.Auth.Default)
          authorization_servers(["https://auth.example.com"])
          resource_documentation("ftp://docs.example.com/mcp")
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'resource_documentation' must be an http(s) URL, got: \"ftp://docs.example.com/mcp\""
      )
    end

    test "raises when filter_by_scope is not a boolean" do
      module("AuthStringFilter") do
        authorization do
          verifier(Support.Auth.Default)
          authorization_servers(["https://auth.example.com"])
          filter_by_scope("yes")
        end
      end
      |> assert_compile_raise(ArgumentError, ~r"'filter_by_scope' must be a boolean.*\"yes\"")
    end

    test "raises when filter_by_scope is an integer" do
      module("AuthIntegerFilter") do
        authorization do
          verifier(Support.Auth.Default)
          authorization_servers(["https://auth.example.com"])
          filter_by_scope(1)
        end
      end
      |> assert_compile_raise(ArgumentError, ~r"'filter_by_scope' must be a boolean.*1")
    end

    test "raises when filter_by_scope is declared two times" do
      module("AuthDuplicateFilter") do
        authorization do
          verifier(Support.Auth.Default)
          authorization_servers(["https://auth.example.com"])
          filter_by_scope(true)
          filter_by_scope(false)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'filter_by_scope' multiple times")
    end

    test "raises when filter_by_scope is used at root level" do
      module("AuthFilterAtRoot") do
        filter_by_scope(false)
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.AuthFilterAtRoot",
        "undefined function filter_by_scope/1"
      )
    end

    test "raises when filter_by_scope is used in another block" do
      module("AuthFilterInTools") do
        tools do
          filter_by_scope(false)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'filter_by_scope' here")
    end

    test "raises when audience_check is not a boolean" do
      module("AuthStringAudienceCheck") do
        authorization do
          verifier(Support.Auth.Default)
          authorization_servers(["https://auth.example.com"])
          audience_check("yes")
        end
      end
      |> assert_compile_raise(ArgumentError, ~r"'audience_check' must be a boolean.*\"yes\"")
    end

    test "raises when audience_check is declared two times" do
      module("AuthDuplicateAudienceCheck") do
        authorization do
          verifier(Support.Auth.Default)
          authorization_servers(["https://auth.example.com"])
          audience_check(true)
          audience_check(false)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'audience_check' multiple times")
    end

    test "raises when audience_check is used at root level" do
      module("AuthAudienceCheckAtRoot") do
        audience_check(false)
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.AuthAudienceCheckAtRoot",
        "undefined function audience_check/1"
      )
    end

    test "raises when audience_check is used in another block" do
      module("AuthAudienceCheckInTools") do
        tools do
          audience_check(false)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'audience_check' here")
    end

    test "raises when a property is declared two times" do
      module("AuthDuplicateProperty") do
        authorization do
          verifier(Support.Auth.Default)
          verifier(Support.Auth.Default)
          authorization_servers(["https://auth.example.com"])
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'verifier' multiple times")
    end

    test "raises when a property is used at root level" do
      module("AuthPropertyAtRoot") do
        verifier(Support.Auth.Default)
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.AuthPropertyAtRoot",
        "undefined function verifier/1"
      )
    end

    test "raises when a property is used in another block" do
      module("AuthPropertyInTools") do
        tools do
          authorization_servers(["https://auth.example.com"])
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'authorization_servers' here")
    end

    test "raises when authorization is declared two times" do
      module("AuthDuplicateBlock") do
        authorization do
          verifier(Support.Auth.Default)
          authorization_servers(["https://auth.example.com"])
        end

        authorization do
          verifier(Support.Auth.Default)
          authorization_servers(["https://auth.example.com"])
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'authorization' multiple times")
    end

    test "raises when authorization is used inside another block" do
      module("AuthBlockInTools") do
        tools do
          authorization do
            verifier(Support.Auth.Default)
            authorization_servers(["https://auth.example.com"])
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'authorization' here")
    end

    # -----------------------------------------------------------------------
    # Not a capability
    # -----------------------------------------------------------------------

    test "authorization is not part of the initialize result" do
      with_auth =
        module("AuthWithInit") do
          authorization do
            verifier(Support.Auth.Default)
            authorization_servers(["https://auth.example.com"])
          end
        end
        |> compile()

      without_auth =
        module("AuthWithoutInit") do
          :ok
        end
        |> compile()

      assert with_auth.initialize_result() == without_auth.initialize_result()
      assert Map.has_key?(with_auth.initialize_result().capabilities, :authorization) == false
    end
  end

  describe "behaviour" do
    test "authorization/0 is an optional callback" do
      optional_callbacks = OzMcp.Config.Server.behaviour_info(:optional_callbacks)

      assert {:authorization, 0} in optional_callbacks
      assert {:roots_list_changed, 1} in optional_callbacks
    end

    test "a hand-written server module without authorization/0 still compiles" do
      refute function_exported?(Servers.TasksStringKeyCaps, :authorization, 0)
    end
  end
end
