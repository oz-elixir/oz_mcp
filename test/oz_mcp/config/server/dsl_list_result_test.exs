#
# Tests for the `list_result/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLListResultTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "list_result/1" do
    # -----------------------------------------------------------------------
    # Accepts (tools)
    # -----------------------------------------------------------------------

    test "accepts a block with meta entries inside tools block" do
      config =
        module("ListResult") do
          tools do
            list_result do
              meta "key", "value"
            end
          end
        end
        |> compile_config()

      assert config.tools.list_result == %{_meta: %{"key" => "value"}, extras: nil}
    end

    test "accepts a block with extra entries inside tools block" do
      config =
        module("ListResult") do
          tools do
            list_result do
              extra "key", "value"
            end
          end
        end
        |> compile_config()

      assert config.tools.list_result == %{_meta: nil, extras: %{"key" => "value"}}
    end

    # -----------------------------------------------------------------------
    # Accepts (resources)
    # -----------------------------------------------------------------------

    test "accepts a block with meta entries inside resources block" do
      config =
        module("ListResult") do
          resources do
            list_result do
              meta "key", "value"
            end
          end
        end
        |> compile_config()

      assert config.resources.list_result == %{_meta: %{"key" => "value"}, extras: nil}
    end

    test "accepts a block with extra entries inside resources block" do
      config =
        module("ListResult") do
          resources do
            list_result do
              extra "key", "value"
            end
          end
        end
        |> compile_config()

      assert config.resources.list_result == %{_meta: nil, extras: %{"key" => "value"}}
    end

    # -----------------------------------------------------------------------
    # Accepts (templates)
    # -----------------------------------------------------------------------

    test "accepts a block with meta entries inside templates block" do
      config =
        module("ListResult") do
          templates do
            list_result do
              meta "key", "value"
            end
          end
        end
        |> compile_config()

      assert config.templates.list_result == %{_meta: %{"key" => "value"}, extras: nil}
    end

    test "accepts a block with extra entries inside templates block" do
      config =
        module("ListResult") do
          templates do
            list_result do
              extra "key", "value"
            end
          end
        end
        |> compile_config()

      assert config.templates.list_result == %{_meta: nil, extras: %{"key" => "value"}}
    end

    # -----------------------------------------------------------------------
    # Accepts (prompts)
    # -----------------------------------------------------------------------

    test "accepts a block with meta entries inside prompts block" do
      config =
        module("ListResult") do
          prompts do
            list_result do
              meta "key", "value"
            end
          end
        end
        |> compile_config()

      assert config.prompts.list_result == %{_meta: %{"key" => "value"}, extras: nil}
    end

    test "accepts a block with extra entries inside prompts block" do
      config =
        module("ListResult") do
          prompts do
            list_result do
              extra "key", "value"
            end
          end
        end
        |> compile_config()

      assert config.prompts.list_result == %{_meta: nil, extras: %{"key" => "value"}}
    end

    test "accepts a block with both meta and extra entries" do
      config =
        module("ListResult") do
          tools do
            list_result do
              meta "mk", "mv"
              extra "ek", "ev"
            end
          end
        end
        |> compile_config()

      assert config.tools.list_result == %{
               _meta: %{"mk" => "mv"},
               extras: %{"ek" => "ev"}
             }
    end

    test "accepts multiple meta and extra entries" do
      config =
        module("ListResult") do
          tools do
            list_result do
              meta "k1", "v1"
              meta "k2", "v2"
              extra "e1", "ev1"
              extra "e2", "ev2"
            end
          end
        end
        |> compile_config()

      assert config.tools.list_result == %{
               _meta: %{"k1" => "v1", "k2" => "v2"},
               extras: %{"e1" => "ev1", "e2" => "ev2"}
             }
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when list_result block is empty" do
      module("ListResult") do
        tools do
          list_result()
        end
      end
      |> assert_compile_raise(RuntimeError, "remove 'list_result', it's empty")
    end

    test "raises when list_result is declared multiple times" do
      module("ListResult") do
        tools do
          list_result do
            meta "key", "value"
          end

          list_result do
            meta "key", "value"
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'list_result' multiple times")
    end

    test "raises when extra key is a field of the tools list result" do
      module("ListResult") do
        tools do
          list_result do
            extra "nextCursor", "2"
          end
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'extra' key \"nextCursor\" is a field of the result, " <>
          "use the field (or 'meta' for \"_meta\")"
      )

      module("ListResult") do
        tools do
          list_result do
            extra "tools", []
          end
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'extra' key \"tools\" is a field of the result, use the field (or 'meta' for \"_meta\")"
      )
    end

    test "accepts an extra key that is a field of another block list result" do
      config =
        module("ListResult") do
          resources do
            list_result do
              extra "tools", []
            end
          end
        end
        |> compile_config()

      assert config.resources.list_result == %{_meta: nil, extras: %{"tools" => []}}
    end

    # -----------------------------------------------------------------------
    # Special
    # -----------------------------------------------------------------------

    test "defaults to nil when list_result is not declared" do
      config =
        module("ListResult") do
          tools(tool: Support.Entities.Tools.SecondTest)
        end
        |> compile_config()

      assert config.tools.list_result == nil
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when list_result is used at root level" do
      module("ListResult") do
        list_result do
        end
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.ListResult",
        "undefined function list_result/1"
      )
    end

    test "raises when list_result is used inside capabilities block" do
      module("ListResult") do
        capabilities do
          list_result do
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'list_result' here")
    end

    test "raises when list_result is used inside server_info block" do
      module("ListResult") do
        server_info do
          list_result do
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'list_result' here")
    end
  end
end
