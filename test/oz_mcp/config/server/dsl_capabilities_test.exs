#
# Tests for the `capabilities/1` macro of the server DSL and for the
# single expansion of the `tools`, `prompts` and `resources` blocks.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLCapabilitiesTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  alias OzMcp.Structs.ServerCapabilities
  alias Support.Helpers.DslBlockCounter, as: Counter
  alias Support.Helpers.Utils

  describe "capabilities/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a capabilities block with experimental" do
      config =
        module("Capabilities") do
          capabilities(experimental: %{feature: %{enabled: true}})
        end
        |> compile_config()

      # The factory auto-injects a `tool`, so a default `tools: %{}` capability
      # is auto-added alongside the declared `experimental`.
      #
      assert config.capabilities ==
               %ServerCapabilities{
                 experimental: %{feature: %{enabled: true}},
                 tools: %{}
               }
    end

    test "accepts a capabilities block with all capability properties" do
      config =
        module("Capabilities") do
          capabilities do
            experimental %{feature: %{}}
            logging %{}
            completions %{}

            tasks do
              list %{a: 1}
              cancel %{b: 2}
              requests %{tools: %{call: %{}}}
            end
          end
        end
        |> compile_config()

      assert config.capabilities == %ServerCapabilities{
               experimental: %{feature: %{}},
               logging: %{},
               completions: %{},
               tasks: %{list: %{a: 1}, cancel: %{b: 2}, requests: %{tools: %{call: %{}}}},
               tools: %{}
             }
    end

    # TODO: an empty capabilities block is currently allowed (the "raise if all
    # keys are nil" check is a TODO in the source). This test documents that
    # current behavior.
    #
    test "accepts an empty capabilities block" do
      config =
        module("Capabilities") do
          capabilities()
        end
        |> compile_config()

      # The block itself is empty, but the auto-injected `tool` triggers a
      # default `tools: %{}` capability.
      #
      assert config.capabilities == %ServerCapabilities{tools: %{}}
    end

    test "gives the capabilities of the entities that the server declares" do
      config =
        module("Capabilities") do
          tools do
            tool(Support.Entities.Tools.SecondTest)
          end

          resources do
            resource(Support.Entities.Resources.FirstTest)
          end

          prompts do
            prompt(Support.Entities.Prompts.FirstTest)
          end

          capabilities do
            cap_resources(subscribe: true)
          end
        end
        |> compile_config()

      assert config.capabilities == %ServerCapabilities{
               tools: %{},
               resources: %{subscribe: true},
               prompts: %{}
             }
    end

    test "accepts a nested resources sub-block (subscribe)" do
      config =
        module("Capabilities") do
          resources()

          capabilities do
            cap_resources(subscribe: true)
          end
        end
        |> compile_config()

      assert config.capabilities == %ServerCapabilities{resources: %{subscribe: true}}
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when capabilities is declared multiple times" do
      module("Capabilities") do
        capabilities(experimental: %{a: 1})
        capabilities(logging: %{})
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'capabilities' multiple times")
    end

    test "raises when tools is used inside capabilities" do
      module("Capabilities") do
        capabilities do
          tools do
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'tools' here")
    end

    test "raises when prompts is used inside capabilities" do
      module("Capabilities") do
        prompts do
          prompt(Support.Entities.Prompts.FirstTest)
        end

        capabilities do
          prompts do
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'prompts' here")
    end

    test "raises when list_changed is used inside capabilities > resources" do
      code = """
      defmodule Support.Generated.Server.ListChangedRefused do
        use OzMcp.Config.Server

        server_info do
          name "refused"
          version "1.0.0"
        end

        resources do
          resource Support.Entities.Resources.FirstTest
        end

        capabilities do
          resources do
            list_changed true
          end
        end
      end
      """

      output =
        Utils.capture_diagnostics(fn ->
          assert_raise CompileError, fn -> Code.compile_string(code) end
        end)

      assert output =~ "list_changed"
    end

    test "raises when nested resources is declared multiple times inside capabilities" do
      module("Capabilities") do
        capabilities do
          cap_resources(subscribe: true)
          cap_resources(subscribe: false)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'resources' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when capabilities is used inside tools block" do
      module("Capabilities") do
        tools do
          capabilities(experimental: %{a: 1})
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'capabilities' here")
    end

    test "raises when capabilities is used inside server_info block" do
      module("Capabilities") do
        server_info do
          capabilities(experimental: %{a: 1})
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'capabilities' here")
    end
  end

  describe "single block expansion" do
    #
    # The counter runs when the module body compiles: a duplicated block
    # would bump the counter two times.
    #

    test "expands the tools block one time at the root" do
      module("ExpandTools") do
        tools do
          tool(Support.Entities.Tools.SecondTest)
          Counter.bump(:tools_root)
        end
      end
      |> compile_config()

      assert Counter.read(:tools_root) == 1
    end

    test "expands the prompts block one time at the root" do
      module("ExpandPrompts") do
        prompts do
          prompt(Support.Entities.Prompts.FirstTest)
          Counter.bump(:prompts_root)
        end
      end
      |> compile_config()

      assert Counter.read(:prompts_root) == 1
    end

    test "expands the resources block one time at the root" do
      module("ExpandResources") do
        resources do
          resource(Support.Entities.Resources.FirstTest)
          Counter.bump(:resources_root)
        end
      end
      |> compile_config()

      assert Counter.read(:resources_root) == 1
    end

    test "expands the resources block one time inside capabilities" do
      module("ExpandCapResources") do
        capabilities do
          cap_resources do
            Counter.bump(:resources_cap)
          end
        end
      end
      |> compile_config()

      assert Counter.read(:resources_cap) == 1
    end
  end
end
