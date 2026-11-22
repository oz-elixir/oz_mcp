defmodule OzMcp.Auth.ScopesTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  alias OzMcp.Auth.{Principal, Scopes}
  alias OzMcp.Structs.Tool
  alias Support.Servers

  require Support.Factories.Tool

  describe "check!/1" do
    test "returns the scopes with no repeated entry" do
      assert Scopes.check!(["a", "b", "a"]) == ["a", "b"]
    end

    test "raises for an empty list, a non-list, a bad token and an improper list" do
      for bad <- [[], "a", nil, ["a b"], [1], ["a" | "b"]] do
        assert_raise ArgumentError, fn -> Scopes.check!(bad) end
      end
    end
  end

  describe "required/1 and visible?/2" do
    test "a struct gives its scopes, a map gives none" do
      assert Scopes.required(%Tool{required_scopes: ["a"]}) == ["a"]
      assert Scopes.required(%{name: "x", required_scopes: ["a"]}) == []
      assert Scopes.required(nil) == []
    end

    test "an entity with no scope is visible, one with scopes needs all of them" do
      principal = Principal.new!(subject: "alice", scopes: ["a"])

      assert Scopes.visible?(%Tool{}, principal)
      assert Scopes.visible?(%Tool{required_scopes: ["a"]}, principal)
      refute Scopes.visible?(%Tool{required_scopes: ["a", "b"]}, principal)
    end
  end

  describe "step_up/3" do
    test "a principal with no granted scope gives the needed scopes" do
      principal = Principal.new!(subject: "alice", scopes: [])

      assert Scopes.step_up(principal, ["files:write"], ["files:read"]) == ["files:write"]
    end

    test "a granted scope that is also needed appears once, the granted scopes come first" do
      principal = Principal.new!(subject: "alice", scopes: ["files:read", "files:write"])

      assert Scopes.step_up(principal, ["files:write", "admin"], []) ==
               ["files:read", "files:write", "admin"]
    end

    test "needed scopes empty means the challenge_scopes of the server" do
      principal = Principal.new!(subject: "alice", scopes: [])

      assert Scopes.step_up(principal, [], ["files:read"]) == ["files:read"]
    end

    test "a granted scope that is not a scope token is dropped" do
      principal = Principal.new!(subject: "alice", scopes: ["files:read write", "files:read"])

      assert Scopes.step_up(principal, ["files:write"], []) ==
               ["files:read", "files:write"]
    end

    test "an empty result when nothing is granted and nothing is needed" do
      principal = Principal.new!(subject: "alice", scopes: [])

      assert Scopes.step_up(principal, [], []) == []
    end
  end

  describe "declared/1" do
    test "the sorted union of the scopes of the DSL modules of the server" do
      #
      # The server has four DSL modules (tools, resources, templates and
      # prompts) and one module with `dsl?: false` that returns plain
      # maps. The union of the scopes is ["admin", "files:write"].
      #
      assert Scopes.declared(Servers.ScopedPaginated) == ["admin", "files:write"]
    end

    test "a server whose modules use dsl?: false has no scope" do
      assert Scopes.declared(Servers.Default) == []
    end

    test "a module that is not a server has no scope" do
      assert Scopes.declared(:no_such_server) == []
    end
  end

  describe "declared/2 with the catalog" do
    #
    # The boot of the instance reads the scopes into the catalog and the
    # read of the catalog is one persistent_term read.
    #
    test "a static map entity adds its scopes" do
      server = map_scoped_server(["tools:write"])

      assert Scopes.declared(server, :tools) == ["tools:write"]
    end

    test "a constant that a module defines itself has no effect" do
      code =
        quote do
          def list do
            [
              %{
                "name" => "plain",
                "description" => "No scope",
                "inputSchema" => %{"type" => "object"}
              }
            ]
          end

          def __required_scopes__, do: ["ghost:scope"]

          def call(_ctx, _params), do: {:ok, %{"content" => []}}
        end

      tool_mod =
        Support.Factories.Tool.module("ScopesConstantTool", _dsl_: false, _code_: code)
        |> Support.Factories.Tool.compile()

      exprs = [Support.Factories.Server.__tools__([], [Support.Factories.Server.tool(tool_mod)])]

      server =
        "ScopesConstantServer"
        |> Support.Factories.Server.__module__([_tools_: :_none_], exprs)
        |> Support.Factories.Server.compile()

      assert Scopes.declared(server, :tools) == []
      assert Scopes.declared(server) == []
    end

    test "the scopes of two modules are unique and sorted" do
      tool_mod = map_scoped_tool(["admin"])

      exprs = [
        Support.Factories.Server.__tools__([], [
          Support.Factories.Server.tool(Support.Entities.Tools.ScopedTest),
          Support.Factories.Server.tool(tool_mod)
        ])
      ]

      server =
        "ScopesMixed"
        |> Support.Factories.Server.__module__([_tools_: :_none_], exprs)
        |> Support.Factories.Server.compile()

      # Support.Entities.Tools.ScopedTest carries ["admin", "files:write"] in its structs
      # and the map of the second module carries ["admin"]. The union
      # shows "admin" once.
      #
      assert Scopes.declared(server, :tools) == ["admin", "files:write"]
    end
  end

  describe "supported/2" do
    test "an explicit list wins, even when it is empty" do
      assert Scopes.supported(Servers.ScopedPaginated, %{scopes_supported: ["custom"]}) ==
               ["custom"]

      assert Scopes.supported(Servers.ScopedPaginated, %{scopes_supported: []}) == []
    end

    test "with nil and scopes in the DSL, the sorted union" do
      assert Scopes.supported(Servers.ScopedPaginated, %{scopes_supported: nil}) ==
               ["admin", "files:write"]
    end

    test "with nil and no scope in the DSL, nil" do
      assert Scopes.supported(Servers.Default, %{scopes_supported: nil}) == nil
    end

    test "with nil and the scopes of a map module, the sorted union" do
      server = map_scoped_server(["tools:write"])

      assert Scopes.supported(server, %{scopes_supported: nil}) == ["tools:write"]
    end
  end

  # A static tool module whose list returns a map with the given scopes
  # and a server that holds the module. The module defines no constant.
  #
  defp map_scoped_tool(scopes) do
    code =
      quote do
        def list do
          [
            %{
              "name" => "scoped_map",
              "description" => "A map tool with scopes",
              "inputSchema" => %{"type" => "object"},
              "required_scopes" => unquote(scopes)
            }
          ]
        end

        def call(_ctx, _params), do: {:ok, %{"content" => []}}
      end

    Support.Factories.Tool.module("ScopesMapTool", _dsl_: false, _code_: code)
    |> Support.Factories.Tool.compile()
  end

  defp map_scoped_server(scopes) do
    tool_mod = map_scoped_tool(scopes)
    exprs = [Support.Factories.Server.__tools__([], [Support.Factories.Server.tool(tool_mod)])]

    "ScopesMapServer"
    |> Support.Factories.Server.__module__([_tools_: :_none_], exprs)
    |> Support.Factories.Server.compile()
  end
end
