#
# Tests for the boot check of the `completions` capability and of the
# `complete/4` callbacks of the entity modules (OzMcp.Config.Completions).
# See: lib/oz_mcp/config/completions.ex
#
defmodule OzMcp.Config.CompletionsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Support.Factories.Server

  alias OzMcp.Config.Completions

  describe "check!/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "gives :ok when the capability is absent and no module defines complete/4" do
      server =
        module "CompletionsBootPlain" do
          tools do
            tool Support.Entities.Tools.DslTest.Basic
          end
        end
        |> compile()

      assert Completions.check!(server) == :ok
    end

    test "gives :ok when a prompt module defines complete/4" do
      server =
        module "CompletionsBootPrompt" do
          prompts do
            prompt Support.Entities.Prompts.FirstTest
          end

          capabilities do
            completions %{}
          end
        end
        |> compile()

      assert Completions.check!(server) == :ok
    end

    test "gives :ok when a template module defines complete/4" do
      server =
        module "CompletionsBootTemplate" do
          templates do
            template Support.Entities.Templates.FirstTest
          end

          capabilities do
            completions %{}
          end
        end
        |> compile()

      assert Completions.check!(server) == :ok
    end

    test "gives :ok when a resource module defines complete/4" do
      server =
        module "CompletionsBootResource" do
          resources do
            resource Support.Entities.Resources.ScopedTest
          end

          capabilities do
            completions %{}
          end
        end
        |> compile()

      assert Completions.check!(server) == :ok
    end

    test "gives :ok when the capability and a callback exist" do
      server =
        module "CompletionsBootBoth" do
          prompts do
            prompt Support.Entities.Prompts.FirstTest
          end

          capabilities do
            completions %{}
          end
        end
        |> compile()

      assert Completions.check!(server) == :ok
    end

    test "gives :ok for a server with no config" do
      assert Completions.check!(OzMcp.Config.Completions) == :ok
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when completions is declared and no module defines complete/4" do
      server =
        module "CompletionsBootNoCallback" do
          prompts do
            prompt Support.Entities.Prompts.DslTest.Basic
          end

          capabilities do
            completions %{}
          end
        end
        |> compile()

      assert_raise ArgumentError,
                   "server #{inspect(server)} declares the completions capability, " <>
                     "but no prompt module, no template module and no resource module " <>
                     "defines complete/4",
                   fn -> Completions.check!(server) end
    end

    test "a dsl?: false module with no complete/4 does not count as a completer" do
      server =
        module "CompletionsBootNoDsl" do
          prompts do
            prompt Support.Entities.Prompts.NoCompleteTest
          end

          capabilities do
            completions %{}
          end
        end
        |> compile()

      assert_raise ArgumentError,
                   ~r"declares the completions capability",
                   fn -> Completions.check!(server) end
    end

    # -----------------------------------------------------------------------
    # Warning
    # -----------------------------------------------------------------------

    test "logs a warning when a module defines complete/4 and the capability is absent" do
      server =
        module "CompletionsBootNoCapability" do
          prompts do
            prompt Support.Entities.Prompts.FirstTest
          end
        end
        |> compile()

      log = capture_log(fn -> Completions.check!(server) end)

      assert log =~ "does not declare the completions capability"
      assert log =~ "complete/4"
    end
  end
end
