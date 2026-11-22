# The equivalence of the three forms of an entity: the struct, the
# atom-key map and the string-key map of one generated entity give one
# catalog entry, one answer of find, one list entry and one bound
# entity at the read of the request path.
# See: lib/oz_mcp/catalog.ex, lib/oz_mcp/catalog/normalize.ex,
# lib/oz_mcp/handler/page.ex
#

#
# A static tool module whose entity comes from :persistent_term, so a
# run of the test writes the form of the entity and boots a server.
#
defmodule EntityForms.ToolStore do
  use OzMcp.Config.Tool, dsl?: false, warn?: false

  alias OzMcp.Structs.{CallToolResult, TextContent, Tool}

  @entity %Tool{name: "form_default", inputSchema: %{type: "object"}}

  def list, do: [current()]

  def call(_ctx, _params) do
    {:ok,
     %CallToolResult{}
     |> CallToolResult.content([%TextContent{} |> TextContent.text("bound")])
     |> CallToolResult.structured_content(%{})
     |> CallToolResult.build()}
  end

  def put(entity), do: :persistent_term.put({__MODULE__, :entity}, entity)

  defp current, do: :persistent_term.get({__MODULE__, :entity}, @entity)
end

defmodule EntityForms.PromptStore do
  use OzMcp.Config.Prompt, dsl?: false, warn?: false

  alias OzMcp.Structs.{GetPromptResult, Prompt, PromptMessage, TextContent}

  @entity %Prompt{name: "form_default"}

  def list, do: [current()]

  def get(_ctx, _params) do
    {:ok,
     %GetPromptResult{}
     |> GetPromptResult.messages([
       %PromptMessage{role: :user, content: %TextContent{} |> TextContent.text("bound")}
     ])
     |> GetPromptResult.build()}
  end

  def put(entity), do: :persistent_term.put({__MODULE__, :entity}, entity)

  defp current, do: :persistent_term.get({__MODULE__, :entity}, @entity)
end

defmodule EntityForms.ResourceStore do
  use OzMcp.Config.Resource, dsl?: false, warn?: false

  alias OzMcp.Structs.{ReadResourceResult, Resource, TextResourceContents}

  @entity %Resource{uri: "file:///form-default.md", name: "form-default"}

  def list, do: [current()]

  def read(_ctx, %{"uri" => uri} = _params) do
    {:ok,
     %ReadResourceResult{}
     |> ReadResourceResult.contents([
       %TextResourceContents{}
       |> TextResourceContents.uri(uri)
       |> TextResourceContents.mime_type("text/markdown")
       |> TextResourceContents.text("bound")
     ])
     |> ReadResourceResult.build()}
  end

  def put(entity), do: :persistent_term.put({__MODULE__, :entity}, entity)

  defp current, do: :persistent_term.get({__MODULE__, :entity}, @entity)
end

defmodule EntityForms.TemplateStore do
  use OzMcp.Config.Template, dsl?: false, warn?: false

  alias OzMcp.Structs.{ReadResourceResult, ResourceTemplate, TextResourceContents}

  @entity %ResourceTemplate{uriTemplate: "file:///form/{path}", name: "form-default"}

  def list, do: [current()]

  def read(_ctx, params, _uri_template, _uri_params) do
    {:ok,
     %ReadResourceResult{}
     |> ReadResourceResult.contents([
       %TextResourceContents{}
       |> TextResourceContents.uri(params["uri"])
       |> TextResourceContents.mime_type("text/markdown")
       |> TextResourceContents.text("bound")
     ])
     |> ReadResourceResult.build()}
  end

  def put(entity), do: :persistent_term.put({__MODULE__, :entity}, entity)

  defp current, do: :persistent_term.get({__MODULE__, :entity}, @entity)
end

defmodule EntityForms.Server do
  use OzMcp.Config.Server

  server_info do
    name "entity-forms"
    version "1.0.0"
  end

  tools do
    tool EntityForms.ToolStore
  end

  prompts do
    prompt EntityForms.PromptStore
  end

  resources do
    resource EntityForms.ResourceStore
  end

  templates do
    template EntityForms.TemplateStore
  end
end

defmodule OzMcp.EntityFormsTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Bench.Runner
  alias OzMcp.Catalog
  alias Support.Helpers.Utils

  @max_runs 50

  # The URI of a resources/read of the template: each generated template
  # matches it.
  #
  @template_uri "file:///docs/report.md"

  @kinds [:tools, :prompts, :resources, :templates]

  @configs %{
    tools: %{
      store: EntityForms.ToolStore,
      list_method: "tools/list",
      list_key: "tools",
      read_method: "tools/call"
    },
    prompts: %{
      store: EntityForms.PromptStore,
      list_method: "prompts/list",
      list_key: "prompts",
      read_method: "prompts/get"
    },
    resources: %{
      store: EntityForms.ResourceStore,
      list_method: "resources/list",
      list_key: "resources",
      read_method: "resources/read"
    },
    templates: %{
      store: EntityForms.TemplateStore,
      list_method: "resources/templates/list",
      list_key: "resourceTemplates",
      read_method: "resources/read"
    }
  }

  property "an entity of each kind in three forms gives one catalog entry, one answer of find, one list entry and one read" do
    check all tool <- Support.Helpers.EntityGen.tool(),
              prompt <- Support.Helpers.EntityGen.prompt(),
              resource <- Support.Helpers.EntityGen.resource(),
              template <- Support.Helpers.EntityGen.template(),
              max_runs: @max_runs do
      entities = %{tools: tool, prompts: prompt, resources: resource, templates: template}

      observed = for index <- 0..2, do: observe(index, entities)

      for kind <- @kinds do
        assert_one(observed, &Map.fetch!(&1.entries, kind), "the catalog entry of #{kind}")
        assert_one(observed, &Map.fetch!(&1.found, kind), "the answer of find of #{kind}")
        assert_one(observed, &Map.fetch!(&1.lists, kind), "the list entry of #{kind}")
        assert_one(observed, &Map.fetch!(&1.reads, kind), "the answer of the read of #{kind}")
      end
    end
  end

  # The two map forms carry an unknown key in extras, each in its own
  # key form and the JSON of the list entry holds it once.
  #
  test "an unknown key of a map entity reaches the list entry from extras" do
    atom_entry =
      list_entry(:tools, %{
        name: "vendor_tool",
        title: "The vendor tool",
        inputSchema: %{type: "object"},
        vendor: 1
      })

    string_entry =
      list_entry(:tools, %{
        "name" => "vendor_tool",
        "title" => "The vendor tool",
        "inputSchema" => %{"type" => "object"},
        "vendor" => 1
      })

    assert atom_entry == string_entry
    assert atom_entry["name"] == "vendor_tool"
    assert atom_entry["vendor"] == 1
  end

  # ------------------------------------------------------------------
  # The check of one form of one entity of each kind
  # ------------------------------------------------------------------

  defp assert_one(observed, get, what) do
    values = Enum.map(observed, get)
    assert [first | rest] = values
    assert Enum.all?(rest, &(&1 == first)), "#{what} differs between the three forms"
  end

  # One boot of the server reads the form of index `index` of each kind:
  # the catalog entry and the answer of find are read from the built
  # catalog and the list entry and the answer of the read come from a
  # request of the server.
  #
  defp observe(index, entities) do
    forms =
      Map.new(@kinds, fn kind ->
        {kind, Enum.at(Support.Helpers.EntityGen.forms(Map.fetch!(entities, kind)), index)}
      end)

    Enum.each(@kinds, fn kind ->
      config = Map.fetch!(@configs, kind)
      config.store.put(Map.fetch!(forms, kind))
    end)

    catalog = Catalog.build!(EntityForms.Server)

    entries =
      Map.new(@kinds, fn kind ->
        config = Map.fetch!(@configs, kind)
        {kind, Catalog.entries(config.store, kind)}
      end)

    found =
      Map.new(@kinds, fn kind -> {kind, find(kind, catalog, Map.fetch!(entities, kind))} end)

    {name, session} = start()

    try do
      lists =
        Map.new(@kinds, fn kind ->
          config = Map.fetch!(@configs, kind)
          {kind, list_entry(name, session, config)}
        end)

      reads =
        Map.new(@kinds, fn kind ->
          config = Map.fetch!(@configs, kind)
          {kind, read_answer(name, session, config, Map.fetch!(entities, kind))}
        end)

      %{entries: entries, found: found, lists: lists, reads: reads}
    after
      Utils.stop_instance(name)
    end
  end

  defp find(kind, catalog, entity) do
    case kind do
      :tools -> Catalog.find_tool(catalog, entity.name)
      :prompts -> Catalog.find_prompt(catalog, entity.name)
      :resources -> Catalog.find_resource(catalog, entity.uri)
      :templates -> Catalog.find_template(catalog, @template_uri)
    end
  end

  defp list_entry(name, session, config) do
    %{"result" => result} = answer(name, session, config.list_method)
    [entry] = Map.fetch!(result, config.list_key)
    entry
  end

  defp read_answer(name, session, config, entity) do
    params =
      case config.read_method do
        "tools/call" -> %{"name" => entity.name, "arguments" => %{"text" => "x"}}
        "prompts/get" -> %{"name" => entity.name, "arguments" => prompt_arguments(entity)}
        "resources/read" when config.list_key == "resources" -> %{"uri" => entity.uri}
        "resources/read" -> %{"uri" => @template_uri}
      end

    answer(name, session, config.read_method, params)
  end

  defp prompt_arguments(prompt) do
    (prompt.arguments || []) |> Map.new(&{&1.name, "x"})
  end

  # ------------------------------------------------------------------
  # Servers and requests
  # ------------------------------------------------------------------

  defp start do
    name = Module.concat(EntityForms.Server, "T#{System.unique_integer([:positive])}")
    Utils.start_instance(EntityForms.Server, name: name)
    {name, Utils.create_session(name, initialized: true)}
  end

  defp list_entry(kind, form) do
    config = Map.fetch!(@configs, kind)
    config.store.put(form)
    {name, session} = start()

    try do
      list_entry(name, session, config)
    after
      Utils.stop_instance(name)
    end
  end

  defp answer(name, session, method, params \\ %{}) do
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
    conn = Runner.post(name, session, body)
    assert conn.status == 200
    :json.decode(conn.resp_body)
  end
end
