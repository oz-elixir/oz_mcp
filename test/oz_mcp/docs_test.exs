#
# The facts of the public documentation that the code owns: the helpers
# of `OzMcp.Context` are documented and its framework functions are
# hidden, each callback of a behaviour module has a doc and each entity
# moduledoc links its guide. The tests do not pin a sentence of a doc.
#
defmodule OzMcp.DocsTest do
  use ExUnit.Case, async: true

  # The layout of the text (line ends, indentation) is not under test.
  #
  defp moduledoc!(module) do
    {:docs_v1, _anno, _language, _format, %{"en" => moduledoc}, _metadata, _docs} =
      Code.fetch_docs(module)

    String.replace(moduledoc, ~r/\s+/, " ")
  end

  defp docs!(module) do
    {:docs_v1, _anno, _language, _format, _moduledoc, _metadata, docs} = Code.fetch_docs(module)
    docs
  end

  describe "OzMcp.Context function visibility" do
    test "documents the helpers and hides the functions of the framework" do
      docs = docs!(OzMcp.Context)

      for name <- [:client_supports?, :capability?] do
        assert {{:function, ^name, 2}, _anno, _signature, %{"en" => doc}, _meta} =
                 Enum.find(docs, fn
                   {{:function, n, 2}, _, _, _, _} -> n == name
                   _ -> false
                 end),
               "OzMcp.Context.#{name}/2 has no doc"

        assert doc != ""
      end

      hidden = [
        new: 4,
        put_http_conn: 2,
        put_rpc: 2,
        request?: 1,
        put_error: 4,
        to_ctx: 1,
        fetch_client_capabilities: 1
      ]

      for {name, arity} <- hidden do
        assert {{:function, ^name, ^arity}, _anno, _signature, :hidden, _meta} =
                 Enum.find(docs, fn
                   {{:function, n, a}, _, _, _, _} -> n == name and a == arity
                   _ -> false
                 end),
               "OzMcp.Context.#{name}/#{arity} must be hidden"
      end
    end
  end

  describe "the callbacks of the behaviour modules" do
    test "each callback has a doc" do
      documented = [
        {OzMcp.Config.Server,
         [
           initialize_result: 0,
           roots_list_changed: 1,
           authorization: 0,
           paginate_tools: 0,
           paginate_resources: 0,
           paginate_templates: 0,
           paginate_prompts: 0
         ]},
        {OzMcp.Config.Tool, [list: 0, call: 2]},
        {OzMcp.Config.Resource, [list: 0, read: 2, complete: 4]},
        {OzMcp.Config.Template, [list: 0, read: 4, complete: 4]},
        {OzMcp.Config.Prompt, [list: 0, get: 2, complete: 4]}
      ]

      for {module, callbacks} <- documented,
          {name, arity} <- callbacks do
        assert {{:callback, ^name, ^arity}, _anno, _signature, %{"en" => doc}, _meta} =
                 Enum.find(docs!(module), fn
                   {{:callback, n, a}, _, _, _, _} -> n == name and a == arity
                   _ -> false
                 end),
               "#{inspect(module)}.#{name}/#{arity} has no doc"

        assert doc != ""
      end
    end
  end

  describe "the Four ways section of the entity moduledocs" do
    setup do
      %{
        moduledocs: %{
          OzMcp.Config.Tool => moduledoc!(OzMcp.Config.Tool),
          OzMcp.Config.Resource => moduledoc!(OzMcp.Config.Resource),
          OzMcp.Config.Template => moduledoc!(OzMcp.Config.Template),
          OzMcp.Config.Prompt => moduledoc!(OzMcp.Config.Prompt)
        }
      }
    end

    test "each entity moduledoc links its guide", %{moduledocs: moduledocs} do
      guides = %{
        OzMcp.Config.Tool => "guides/entities/tools.md",
        OzMcp.Config.Resource => "guides/entities/resources.md",
        OzMcp.Config.Template => "guides/entities/templates.md",
        OzMcp.Config.Prompt => "guides/entities/prompts.md"
      }

      for {module, moduledoc} <- moduledocs do
        assert moduledoc =~ "](#{Map.fetch!(guides, module)})",
               "#{inspect(module)} has no link to its guide"
      end
    end
  end

  describe "the DSL moduledocs" do
    setup do
      %{
        moduledocs: %{
          OzMcp.Config.Tool.DSL => moduledoc!(OzMcp.Config.Tool.DSL),
          OzMcp.Config.Resource.DSL => moduledoc!(OzMcp.Config.Resource.DSL),
          OzMcp.Config.Template.DSL => moduledoc!(OzMcp.Config.Template.DSL),
          OzMcp.Config.Prompt.DSL => moduledoc!(OzMcp.Config.Prompt.DSL)
        }
      }
    end

    test "each DSL moduledoc links its guide", %{moduledocs: moduledocs} do
      guides = %{
        OzMcp.Config.Tool.DSL => "guides/entities/tools.md",
        OzMcp.Config.Resource.DSL => "guides/entities/resources.md",
        OzMcp.Config.Template.DSL => "guides/entities/templates.md",
        OzMcp.Config.Prompt.DSL => "guides/entities/prompts.md"
      }

      for {module, moduledoc} <- moduledocs do
        assert moduledoc =~ "](#{Map.fetch!(guides, module)})",
               "#{inspect(module)} has no link to its guide"
      end
    end
  end
end
