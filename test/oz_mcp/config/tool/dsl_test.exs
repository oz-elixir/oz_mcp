#
# Tests for the tool DSL (OzMcp.Config.Tool.DSL).
# Covers `build`/integration, `__using__/1` and `__before_compile__/1`.
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  alias OzMcp.Structs.{Icon, Tool, ToolAnnotations, ToolExecution}

  describe "build" do
    # -----------------------------------------------------------------------
    # Build
    # -----------------------------------------------------------------------

    test "builds a tool with title, description, input_schema and output_schema" do
      [t] = Support.Entities.Tools.DslTest.Basic.list()

      accepted = %Tool{
        icons: nil,
        name: "get_date",
        title: "Get the current date",
        description: "Get the current date formatted as %d/%m/%Y",
        inputSchema: %{type: "object", properties: %{}},
        execution: nil,
        outputSchema: %{type: "object", properties: %{}},
        annotations: nil,
        _meta: nil
      }

      assert t == accepted
    end

    test "builds a tool with annotations" do
      [t] = Support.Entities.Tools.DslTest.WithAnnotations.list()

      accepted = %Tool{
        icons: nil,
        name: "doc",
        title: "Doc",
        description: "A doc",
        inputSchema: %{},
        execution: nil,
        outputSchema: nil,
        annotations: %ToolAnnotations{
          title: "Safe doc lookup",
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false
        },
        _meta: nil
      }

      assert t == accepted
    end

    test "builds a tool with icons" do
      [t] = Support.Entities.Tools.DslTest.WithIcons.list()

      accepted = %Tool{
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
        inputSchema: %{},
        execution: nil,
        outputSchema: nil,
        annotations: nil,
        _meta: nil
      }

      assert t == accepted
    end

    test "builds a tool with meta" do
      [t] = Support.Entities.Tools.DslTest.WithMeta.list()

      accepted = %Tool{
        icons: nil,
        name: "doc",
        title: "Doc",
        description: "A doc",
        inputSchema: %{},
        execution: nil,
        outputSchema: nil,
        annotations: nil,
        _meta: %{"key1" => "value1", "key2" => "value2"}
      }

      assert t == accepted
    end

    test "builds a tool with execution" do
      [t] = Support.Entities.Tools.DslTest.WithExecution.list()

      accepted = %Tool{
        icons: nil,
        name: "doc",
        title: "Doc",
        description: "A doc",
        inputSchema: %{},
        execution: %ToolExecution{taskSupport: "optional"},
        outputSchema: nil,
        annotations: nil,
        _meta: nil
      }

      assert t == accepted
    end

    test "builds multiple tools" do
      tools = Support.Entities.Tools.DslTest.Multiple.list()

      accepted = [
        %Tool{
          icons: nil,
          name: "first",
          title: "First",
          description: "First tool",
          inputSchema: %{},
          execution: nil,
          outputSchema: nil,
          annotations: nil,
          _meta: nil
        },
        %Tool{
          icons: nil,
          name: "second",
          title: "Second",
          description: "Second tool",
          inputSchema: %{},
          execution: nil,
          outputSchema: nil,
          annotations: nil,
          _meta: nil
        }
      ]

      assert tools == accepted
    end

    test "builds a tool with all features combined" do
      [t] = Support.Entities.Tools.DslTest.Full.list()

      accepted = %Tool{
        icons: [
          %Icon{
            src: "https://assets/icon.svg",
            mimeType: "image/svg+xml",
            sizes: ["16x16", "32x32"],
            theme: "light"
          }
        ],
        name: "full",
        title: "Full Tool",
        description: "A tool with everything",
        inputSchema: %{type: "object", properties: %{name: %{type: "string"}}},
        execution: %ToolExecution{taskSupport: "required"},
        outputSchema: %{type: "object", properties: %{result: %{type: "string"}}},
        annotations: %ToolAnnotations{
          title: "Full tool hints",
          readOnlyHint: false,
          destructiveHint: true,
          idempotentHint: false,
          openWorldHint: true
        },
        _meta: %{"version" => "1.0"}
      }

      assert t == accepted
    end
  end

  describe "__using__/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts use OzMcp.Config.Tool.DSL, warn?: true" do
      code = """
      defmodule Support.Entities.Tools.DslTest.UsingWarnTrue do
        use OzMcp.Config.Tool.DSL, warn?: true

        tool "get_date" do
          title "using-warn-true"
          description "desc"
        end

        def call(_ctx, _params), do: {:error, :no_tool}
      end
      """

      [{mod, _}] = Code.compile_string(code)
      assert hd(mod.list()).name == "get_date"
    end

    test "accepts use OzMcp.Config.Tool.DSL, warn?: false" do
      code = """
      defmodule Support.Entities.Tools.DslTest.UsingWarnFalse do
        use OzMcp.Config.Tool.DSL, warn?: false

        tool "get_date" do
          title "using-warn-false"
          description "desc"
        end

        def call(_ctx, _params), do: {:error, :no_tool}
      end
      """

      [{mod, _}] = Code.compile_string(code)
      assert hd(mod.list()).title == "using-warn-false"
    end

    test "accepts use OzMcp.Config.Tool.DSL without the :warn? option (defaults to true)" do
      #
      # NOTE: Unlike the Server DSL, the Tool DSL does NOT require `:warn?`.
      #
      code = """
      defmodule Support.Entities.Tools.DslTest.UsingWarnMissing do
        use OzMcp.Config.Tool.DSL

        tool "get_date" do
          title "using-warn-missing"
          description "desc"
        end

        def call(_ctx, _params), do: {:error, :no_tool}
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
      defmodule Support.Entities.Tools.DslTest.UsingWarnNotBoolean do
        use OzMcp.Config.Tool.DSL, warn?: "yes"

        tool "get_date" do
          title "using-warn-not-boolean"
          description "desc"
        end

        def call(_ctx, _params), do: {:error, :no_tool}
      end
      """

      assert_raise BadBooleanError, fn ->
        Code.compile_string(code)
      end
    end

    test "does NOT register @behaviour OzMcp.Config.Tool (no call/1 requirement)" do
      code = """
      defmodule Support.Entities.Tools.DslTest.RawDslNoBehaviour do
        use OzMcp.Config.Tool.DSL, warn?: false

        tool "get_date" do
          title "no-behaviour"
          description "desc"
        end
      end
      """

      [{mod, _}] = Code.compile_string(code)

      assert function_exported?(mod, :list, 0)
      refute function_exported?(mod, :call, 1)
    end
  end

  describe "__before_compile__/1" do
    # -----------------------------------------------------------------------
    # Special
    # -----------------------------------------------------------------------

    test "DSL defines list/0 and no list/1, count/0 or find/1" do
      Code.ensure_loaded(Support.Entities.Tools.DslTest.Basic)
      Code.ensure_loaded(Support.Entities.Tools.DslTest.Multiple)

      assert function_exported?(Support.Entities.Tools.DslTest.Basic, :list, 0)
      refute function_exported?(Support.Entities.Tools.DslTest.Basic, :find, 1)
      refute function_exported?(Support.Entities.Tools.DslTest.Basic, :list, 1)
      refute function_exported?(Support.Entities.Tools.DslTest.Basic, :count, 0)
      assert function_exported?(Support.Entities.Tools.DslTest.Multiple, :list, 0)
      refute function_exported?(Support.Entities.Tools.DslTest.Multiple, :find, 1)
    end

    test "list/0 returns the declared tools" do
      assert Enum.map(Support.Entities.Tools.DslTest.Basic.list(), & &1.name) == ["get_date"]

      assert Enum.map(Support.Entities.Tools.DslTest.Multiple.list(), & &1.name) == [
               "first",
               "second"
             ]
    end

    test "__catalog__/0 returns one entry per tool, in the order of the declarations" do
      assert [%OzMcp.Catalog.Entry{} = entry] = Support.Entities.Tools.DslTest.Basic.__catalog__()
      assert entry.key == "get_date"
      assert entry.entity == hd(Support.Entities.Tools.DslTest.Basic.list())
      assert entry.matcher == nil

      catalog = Support.Entities.Tools.DslTest.Multiple.__catalog__()
      assert Enum.map(catalog, & &1.key) == ["first", "second"]
      assert Enum.map(catalog, & &1.entity) == Support.Entities.Tools.DslTest.Multiple.list()
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when module defines list/0 while using tool DSL" do
      code =
        quote do
          def list, do: []
        end

      module("BeforeCompile", _code_: code) do
        tool("get_date")
      end
      |> assert_compile_raise(
        RuntimeError,
        "when using the tool DSL you can't declare list/0 function"
      )
    end

    test "raises when no tool is defined" do
      module("BeforeCompile")
      |> assert_compile_raise(
        RuntimeError,
        "you must at least define one tool"
      )
    end
  end
end
