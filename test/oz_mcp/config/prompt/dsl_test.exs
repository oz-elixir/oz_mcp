#
# Tests for the prompt DSL (OzMcp.Config.Prompt.DSL).
# Covers `build`/integration, `__using__/1` and `__before_compile__/1`.
# See: lib/oz_mcp/config/prompt/dsl.ex
#
defmodule OzMcp.Config.Prompt.DSLTest do
  use ExUnit.Case, async: true

  import Support.Factories.Prompt

  alias OzMcp.Structs.{Icon, Prompt, PromptArgument}

  describe "build" do
    # -----------------------------------------------------------------------
    # Build
    # -----------------------------------------------------------------------

    test "builds a prompt with title, description and an argument" do
      [p] = Support.Entities.Prompts.DslTest.Basic.list()

      accepted = %Prompt{
        icons: nil,
        name: "code_review",
        title: "Code review",
        description: "Reviews code",
        arguments: [
          %PromptArgument{
            name: "language",
            title: nil,
            description: "Programming language",
            required: true
          }
        ],
        _meta: nil
      }

      assert p == accepted
    end

    test "builds a prompt without arguments (arguments are optional per spec)" do
      [p] = Support.Entities.Prompts.DslTest.NoArguments.list()

      accepted = %Prompt{
        icons: nil,
        name: "greeting",
        title: "Greeting",
        description: "A prompt without arguments",
        arguments: nil,
        _meta: nil
      }

      assert p == accepted
    end

    test "builds a prompt with icons" do
      [p] = Support.Entities.Prompts.DslTest.WithIcons.list()

      accepted = %Prompt{
        icons: [
          %Icon{
            src: "https://assets/picto.png",
            mimeType: "image/png",
            sizes: nil,
            theme: nil
          },
          %Icon{
            src: "https://assets/hero.png",
            mimeType: "image/jpeg",
            sizes: ["1200x800"],
            theme: "dark"
          }
        ],
        name: "doc",
        title: "Doc",
        description: "A doc",
        arguments: nil,
        _meta: nil
      }

      assert p == accepted
    end

    test "builds a prompt with meta" do
      [p] = Support.Entities.Prompts.DslTest.WithMeta.list()

      accepted = %Prompt{
        icons: nil,
        name: "doc",
        title: "Doc",
        description: "A doc",
        arguments: nil,
        _meta: %{"key1" => "value1", "key2" => "value2"}
      }

      assert p == accepted
    end

    test "builds multiple prompts" do
      prompts = Support.Entities.Prompts.DslTest.Multiple.list()

      accepted = [
        %Prompt{
          icons: nil,
          name: "first",
          title: "First",
          description: "First prompt",
          arguments: nil,
          _meta: nil
        },
        %Prompt{
          icons: nil,
          name: "second",
          title: "Second",
          description: "Second prompt",
          arguments: nil,
          _meta: nil
        }
      ]

      assert prompts == accepted
    end

    test "builds a prompt with all features combined" do
      [p] = Support.Entities.Prompts.DslTest.Full.list()

      accepted = %Prompt{
        icons: [
          %Icon{
            src: "https://assets/icon.svg",
            mimeType: "image/svg+xml",
            sizes: ["16x16", "32x32"],
            theme: "light"
          }
        ],
        name: "full",
        title: "Full Prompt",
        description: "A prompt with everything",
        arguments: [
          %PromptArgument{
            name: "language",
            title: "Language",
            description: "Programming language",
            required: true
          },
          %PromptArgument{
            name: "focus",
            title: nil,
            description: "security | performance | style",
            required: nil
          }
        ],
        _meta: %{"version" => "1.0"}
      }

      assert p == accepted
    end
  end

  describe "__using__/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts use OzMcp.Config.Prompt.DSL, warn?: true" do
      code = """
      defmodule Support.Entities.Prompts.DslTest.UsingWarnTrue do
        use OzMcp.Config.Prompt.DSL, warn?: true

        prompt "code_review" do
          title "using-warn-true"
          description "desc"
        end

        def get(_ctx, _params), do: {:error, :no_prompt}
      end
      """

      [{mod, _}] = Code.compile_string(code)
      assert hd(mod.list()).name == "code_review"
    end

    test "accepts use OzMcp.Config.Prompt.DSL, warn?: false" do
      code = """
      defmodule Support.Entities.Prompts.DslTest.UsingWarnFalse do
        use OzMcp.Config.Prompt.DSL, warn?: false

        prompt "code_review" do
          title "using-warn-false"
          description "desc"
        end

        def get(_ctx, _params), do: {:error, :no_prompt}
      end
      """

      [{mod, _}] = Code.compile_string(code)
      assert hd(mod.list()).title == "using-warn-false"
    end

    test "accepts use OzMcp.Config.Prompt.DSL without the :warn? option (defaults to true)" do
      #
      # NOTE: Unlike the Server DSL, the Prompt DSL does NOT require `:warn?`.
      #
      code = """
      defmodule Support.Entities.Prompts.DslTest.UsingWarnMissing do
        use OzMcp.Config.Prompt.DSL

        prompt "code_review" do
          title "using-warn-missing"
          description "desc"
        end

        def get(_ctx, _params), do: {:error, :no_prompt}
      end
      """

      [{mod, _}] = Code.compile_string(code)
      assert hd(mod.list()).title == "using-warn-missing"
    end

    # -----------------------------------------------------------------------
    # Special
    # -----------------------------------------------------------------------

    test "does NOT validate :warn? (non-boolean raises BadBooleanError, not 'warn? option must be a boolean')" do
      code = """
      defmodule Support.Entities.Prompts.DslTest.UsingWarnNotBoolean do
        use OzMcp.Config.Prompt.DSL, warn?: "yes"

        prompt "code_review" do
          title "using-warn-not-boolean"
          description "desc"
        end

        def get(_ctx, _params), do: {:error, :no_prompt}
      end
      """

      assert_raise BadBooleanError, fn ->
        Code.compile_string(code)
      end
    end

    test "does NOT register @behaviour OzMcp.Config.Prompt (no get/2 requirement)" do
      code = """
      defmodule Support.Entities.Prompts.DslTest.RawDslNoBehaviour do
        use OzMcp.Config.Prompt.DSL, warn?: false

        prompt "code_review" do
          title "no-behaviour"
          description "desc"
        end
      end
      """

      [{mod, _}] = Code.compile_string(code)

      assert function_exported?(mod, :list, 0)
      refute function_exported?(mod, :get, 2)
    end
  end

  describe "__before_compile__/1" do
    # -----------------------------------------------------------------------
    # Special
    # -----------------------------------------------------------------------

    test "DSL defines list/0 and no list/1, count/0 or find/1" do
      Code.ensure_loaded(Support.Entities.Prompts.DslTest.Basic)
      Code.ensure_loaded(Support.Entities.Prompts.DslTest.Multiple)

      assert function_exported?(Support.Entities.Prompts.DslTest.Basic, :list, 0)
      refute function_exported?(Support.Entities.Prompts.DslTest.Basic, :find, 1)
      refute function_exported?(Support.Entities.Prompts.DslTest.Basic, :list, 1)
      refute function_exported?(Support.Entities.Prompts.DslTest.Basic, :count, 0)
      assert function_exported?(Support.Entities.Prompts.DslTest.Multiple, :list, 0)
      refute function_exported?(Support.Entities.Prompts.DslTest.Multiple, :find, 1)
    end

    test "list/0 returns the declared prompts" do
      assert Enum.map(Support.Entities.Prompts.DslTest.Basic.list(), & &1.name) == ["code_review"]

      assert Enum.map(Support.Entities.Prompts.DslTest.Multiple.list(), & &1.name) == [
               "first",
               "second"
             ]
    end

    test "__catalog__/0 returns one entry per prompt, in the order of the declarations" do
      assert [%OzMcp.Catalog.Entry{} = entry] =
               Support.Entities.Prompts.DslTest.Basic.__catalog__()

      assert entry.key == "code_review"
      assert entry.entity == hd(Support.Entities.Prompts.DslTest.Basic.list())
      assert entry.matcher == nil

      catalog = Support.Entities.Prompts.DslTest.Multiple.__catalog__()
      assert Enum.map(catalog, & &1.key) == ["first", "second"]
      assert Enum.map(catalog, & &1.entity) == Support.Entities.Prompts.DslTest.Multiple.list()
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when module defines list/0 while using prompt DSL" do
      code =
        quote do
          def list, do: []
        end

      module("BeforeCompile", _code_: code) do
        prompt("code_review")
      end
      |> assert_compile_raise(
        RuntimeError,
        "when using the prompt DSL you can't declare list/0 function"
      )
    end

    test "raises when no prompt is defined" do
      module("BeforeCompile")
      |> assert_compile_raise(
        RuntimeError,
        "you must at least define one prompt"
      )
    end
  end
end
