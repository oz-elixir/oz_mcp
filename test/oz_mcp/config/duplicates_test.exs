#
# Tests for the boot check of duplicate entity keys in two modules of one
# server (OzMcp.Config.Duplicates).
# See: lib/oz_mcp/config/duplicates.ex
#
defmodule OzMcp.Config.DuplicatesTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  alias OzMcp.Config.Duplicates

  defmodule DupTemplateShapeA do
    use OzMcp.Config.Template, warn?: false

    template "Shape A" do
      uri_template "file:///{a}"
      title "Shape A"
      description "Shape A template"
    end

    def read(_ctx, _rpc_params, _uri_template, _uri_params), do: {:ok, %{}}
  end

  defmodule DupTemplateShapeB do
    use OzMcp.Config.Template, warn?: false

    template "Shape B" do
      uri_template "file:///{b}"
      title "Shape B"
      description "Shape B template"
    end

    def read(_ctx, _rpc_params, _uri_template, _uri_params), do: {:ok, %{}}
  end

  defmodule DupTemplateShapeReserved do
    use OzMcp.Config.Template, warn?: false

    template "Shape reserved" do
      uri_template "file:///{+a}"
      title "Shape reserved"
      description "Shape reserved template"
    end

    def read(_ctx, _rpc_params, _uri_template, _uri_params), do: {:ok, %{}}
  end

  defmodule DupPlainTemplateA do
    use OzMcp.Config.Template, dsl?: false

    @templates [%{"name" => "plain A", "uriTemplate" => "file:///{a}"}]

    def list, do: @templates

    def read(_ctx, _rpc_params, _uri_template, _uri_params), do: {:ok, %{}}
  end

  defmodule DupPlainTemplateB do
    use OzMcp.Config.Template, dsl?: false

    @templates [%{"name" => "plain B", "uriTemplate" => "file:///{b}"}]

    def list, do: @templates

    def read(_ctx, _rpc_params, _uri_template, _uri_params), do: {:ok, %{}}
  end

  describe "check!/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "gives :ok when two tool modules declare different names" do
      server =
        module "DupToolsOk" do
          tools do
            tool Support.Entities.Tools.DslTest.Basic
            tool Support.Entities.Tools.DslTest.Multiple
          end
        end
        |> compile()

      assert Duplicates.check!(server) == :ok
    end

    test "raises when a dsl?: false module has the same name as a DSL module" do
      #
      # Both modules are static: the boot reads their entries, so the
      # duplicate stops the boot.
      #
      server =
        module "DupToolsNoDsl" do
          tools do
            tool Support.Entities.Tools.DslTest.Basic
            tool Support.Entities.Tools.SecondTest
          end
        end
        |> compile()

      assert_raise ArgumentError,
                   "server #{inspect(server)}: the tool name \"get_date\" " <>
                     "is declared in [Support.Entities.Tools.DslTest.Basic, Support.Entities.Tools.SecondTest]",
                   fn -> Duplicates.check!(server) end
    end

    test "gives :ok when a tool and a prompt have the same name" do
      server =
        module "DupKinds" do
          tools do
            tool Support.Entities.Tools.DslTest.WithAnnotations
          end

          prompts do
            prompt Support.Entities.Prompts.DslTest.WithIcons
          end
        end
        |> compile()

      assert Duplicates.check!(server) == :ok
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when two tool modules declare the same tool name" do
      server =
        module "DupTools" do
          tools do
            tool Support.Entities.Tools.DslTest.WithAnnotations
            tool Support.Entities.Tools.DslTest.WithIcons
          end
        end
        |> compile()

      assert_raise ArgumentError,
                   "server #{inspect(server)}: the tool name \"doc\" " <>
                     "is declared in [Support.Entities.Tools.DslTest.WithAnnotations, Support.Entities.Tools.DslTest.WithIcons]",
                   fn -> Duplicates.check!(server) end
    end

    test "raises when two resource modules declare the same uri" do
      server =
        module "DupResources" do
          resources do
            resource Support.Entities.Resources.DslTest.WithIcons
            resource Support.Entities.Resources.DslTest.WithMeta
          end
        end
        |> compile()

      assert_raise ArgumentError,
                   "server #{inspect(server)}: the resource uri \"file:///doc.md\" " <>
                     "is declared in [Support.Entities.Resources.DslTest.WithIcons, Support.Entities.Resources.DslTest.WithMeta]",
                   fn -> Duplicates.check!(server) end
    end

    test "raises when two template modules declare the same uri_template" do
      server =
        module "DupTemplates" do
          templates do
            template Support.Entities.Templates.DslTest.Basic
            template Support.Entities.Templates.DslTest.Multiple
          end
        end
        |> compile()

      assert_raise ArgumentError,
                   "server #{inspect(server)}: the template uri_template \"file://docs/{path}\" " <>
                     "is declared in [Support.Entities.Templates.DslTest.Basic, Support.Entities.Templates.DslTest.Multiple]",
                   fn -> Duplicates.check!(server) end
    end

    test "raises when two prompt modules declare the same prompt name" do
      server =
        module "DupPrompts" do
          prompts do
            prompt Support.Entities.Prompts.DslTest.WithIcons
            prompt Support.Entities.Prompts.DslTest.WithMeta
          end
        end
        |> compile()

      assert_raise ArgumentError,
                   "server #{inspect(server)}: the prompt name \"doc\" " <>
                     "is declared in [Support.Entities.Prompts.DslTest.WithIcons, Support.Entities.Prompts.DslTest.WithMeta]",
                   fn -> Duplicates.check!(server) end
    end

    test "raises when two template modules declare uri_templates with the same shape" do
      server =
        module "DupTemplateShapes" do
          templates do
            template DupTemplateShapeA
            template DupTemplateShapeB
          end
        end
        |> compile()

      assert_raise ArgumentError,
                   "server #{inspect(server)}: the template uri_template \"file:///{b}\" " <>
                     "in OzMcp.Config.DuplicatesTest.DupTemplateShapeB has the same shape as " <>
                     "\"file:///{a}\" in OzMcp.Config.DuplicatesTest.DupTemplateShapeA",
                   fn -> Duplicates.check!(server) end
    end

    test "raises when two dsl?: false template modules declare the same shape" do
      server =
        module "DupPlainTemplateShapes" do
          templates do
            template DupPlainTemplateA
            template DupPlainTemplateB
          end
        end
        |> compile()

      assert_raise ArgumentError,
                   ~r/the template uri_template "file:\/\/\/\{b\}" .* has the same shape as/,
                   fn -> Duplicates.check!(server) end
    end

    test "keeps the exact-duplicate message when a shape duplicate exists too" do
      #
      # Support.Entities.Templates.DslTest.Basic and Support.Entities.Templates.DslTest.Multiple share
      # "file://docs/{path}" (an exact duplicate). DupTemplateShapeB adds
      # a shape duplicate. The exact-key check of all kinds runs first,
      # so the old message wins.
      #
      server =
        module "DupTemplateExactAndShape" do
          templates do
            template Support.Entities.Templates.DslTest.Basic
            template Support.Entities.Templates.DslTest.Multiple
            template DupTemplateShapeB
          end
        end
        |> compile()

      assert_raise ArgumentError,
                   "server #{inspect(server)}: the template uri_template \"file://docs/{path}\" " <>
                     "is declared in [Support.Entities.Templates.DslTest.Basic, Support.Entities.Templates.DslTest.Multiple]",
                   fn -> Duplicates.check!(server) end
    end

    test "gives :ok when two template modules declare uri_templates with different shapes" do
      server =
        module "DupTemplateShapesOk" do
          templates do
            template DupTemplateShapeA
            template DupTemplateShapeReserved
          end
        end
        |> compile()

      assert Duplicates.check!(server) == :ok
    end

    test "raises for the first duplicate key in the sorted order of the keys" do
      #
      # Support.Entities.Tools.DslTest.WithAnnotations and WithIcons share "doc",
      # Support.Entities.Tools.DslTest.Multiple declares "first" and "second". "doc" sorts
      # before "first", so the error names "doc".
      #
      server =
        module "DupToolsThree" do
          tools do
            tool Support.Entities.Tools.DslTest.Multiple
            tool Support.Entities.Tools.DslTest.WithAnnotations
            tool Support.Entities.Tools.DslTest.WithIcons
          end
        end
        |> compile()

      assert_raise ArgumentError,
                   ~r/the tool name "doc" /,
                   fn -> Duplicates.check!(server) end
    end
  end
end
