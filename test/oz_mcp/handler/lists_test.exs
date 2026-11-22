# The list methods and the forms of an entity: the entry of a struct
# tool on the wire, an unknown key of a map entity stays in the answer
# and an entity that fails the build answers the internal error. The
# equality of the three forms of an entity is the property test of
# test/oz_mcp/entity_forms_test.exs.
# See: lib/oz_mcp/handler/page.ex, lib/oz_mcp/handler/lists.ex,
# lib/oz_mcp/auth/listing.ex
#

defmodule ListsForms.Tool do
  use OzMcp.Config.Tool, dsl?: false, warn?: false

  alias OzMcp.Structs.{Tool, ToolExecution}

  @tool %Tool{}
        |> Tool.name("same_tool")
        |> Tool.title("The same tool")
        |> Tool.description("A tool in three forms")
        |> Tool.input_schema(%{"type" => "object"})
        |> Tool.execution(%ToolExecution{taskSupport: :optional})

  def list, do: [@tool]

  def call(_ctx, _params), do: {:ok, %{"content" => []}}
end

defmodule ListsForms.Resource do
  use OzMcp.Config.Resource, dsl?: false, warn?: false

  alias OzMcp.Structs.Resource

  @resource %Resource{}
            |> Resource.uri("file:///same.md")
            |> Resource.name("same.md")
            |> Resource.title("The same resource")
            |> Resource.mime_type("text/markdown")

  def list, do: [@resource]

  def read(_ctx, %{"uri" => uri} = _params) do
    {:ok, %{"contents" => [%{"uri" => uri, "mimeType" => "text/markdown", "text" => "x"}]}}
  end
end

defmodule ListsForms.Template do
  use OzMcp.Config.Template, dsl?: false, warn?: false

  alias OzMcp.Structs.ResourceTemplate

  @template %ResourceTemplate{}
            |> ResourceTemplate.uri_template("file:///same/{name}")
            |> ResourceTemplate.name("same.md")
            |> ResourceTemplate.description("A template in three forms")
            |> ResourceTemplate.mime_type("text/markdown")

  def list, do: [@template]

  def read(_ctx, _params, _uri_template, _uri_params), do: {:error, :not_found}
end

defmodule ListsForms.Prompt do
  use OzMcp.Config.Prompt, dsl?: false, warn?: false

  alias OzMcp.Structs.{Prompt, PromptArgument}

  @prompt %Prompt{}
          |> Prompt.name("same_prompt")
          |> Prompt.description("A prompt in three forms")
          |> Prompt.arguments([
            %PromptArgument{}
            |> PromptArgument.name("lang")
            |> PromptArgument.description("The language")
            |> PromptArgument.required(true)
          ])

  def list, do: [@prompt]

  def get(_ctx, _params), do: {:error, :not_found}
end

defmodule ListsForms.Server do
  use OzMcp.Config.Server

  server_info do
    name "lists-forms-struct"
    version "1.0.0"
  end

  tools do
    tool ListsForms.Tool
  end

  resources do
    resource ListsForms.Resource
  end

  templates do
    template ListsForms.Template
  end

  prompts do
    prompt ListsForms.Prompt
  end
end

#
# A map tool with a key that no field of the struct holds: the normalizer
# keeps it in extras and the list answer shows it.
#
defmodule ListsForms.ExtraKeyTool do
  use OzMcp.Config.Tool, dsl?: false, warn?: false

  @tool %{
    "name" => "vendor_tool",
    "description" => "A map tool with an unknown key",
    "inputSchema" => %{"type" => "object"},
    "vendor" => %{"since" => 2024}
  }

  def list, do: [@tool]

  def call(_ctx, _params), do: {:ok, %{"content" => []}}
end

defmodule ListsForms.ExtraKeyServer do
  use OzMcp.Config.Server

  server_info do
    name "lists-forms-extra-key"
    version "1.0.0"
  end

  tools do
    tool ListsForms.ExtraKeyTool
  end
end

#
# One static module of each kind, with the icons, the _meta and the
# annotations of the Full fixtures and the meta and the extras of the
# list result.
#
defmodule ListsForms.FullServer do
  use OzMcp.Config.Server

  server_info do
    name "lists-forms-full"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.DslTest.Full

    list_result do
      meta "list_meta", "meta value"
      extra "list_extra", "extra value"
    end
  end

  resources do
    resource Support.Entities.Resources.DslTest.Full
  end

  templates do
    template Support.Entities.Templates.DslTest.Full
  end

  prompts do
    prompt Support.Entities.Prompts.DslTest.Full
  end
end

#
# Three static modules of tools, with a page of one entry: the pages
# follow the declared order of the modules.
#
defmodule ListsForms.OrderedServer do
  use OzMcp.Config.Server

  server_info do
    name "lists-forms-ordered"
    version "1.0.0"
  end

  tools do
    paginate 1

    tool Support.Entities.Tools.DslTest.Full
    tool ListsForms.Tool
    tool ListsForms.ExtraKeyTool
  end
end

#
# Three static modules of tools without pagination: the answer of the
# bytes keeps the declared order of the modules.
#
defmodule ListsForms.MixedServer do
  use OzMcp.Config.Server

  server_info do
    name "lists-forms-mixed"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.DslTest.Full
    tool ListsForms.Tool
    tool ListsForms.ExtraKeyTool
  end
end

defmodule OzMcp.Handler.ListsTest do
  use ExUnit.Case, async: true

  alias Bench.Runner
  alias OzMcp.Wire
  alias Support.Helpers.Utils
  alias Support.Servers

  test "the entry of a struct tool holds the execution on the wire" do
    {name, session} = start(ListsForms.Server)

    assert %{"result" => %{"tools" => [entry]}} = answer(name, session, "tools/list")
    assert entry["name"] == "same_tool"
    assert entry["execution"] == %{"taskSupport" => "optional"}
  end

  test "an unknown top-level key of a map tool stays in the list answer" do
    {name, session} = start(ListsForms.ExtraKeyServer)

    assert %{"result" => %{"tools" => [entry]}} = answer(name, session, "tools/list")

    assert entry["name"] == "vendor_tool"
    assert entry["vendor"] == %{"since" => 2024}
  end

  test "the catalog reads each static module one time at boot" do
    Process.register(self(), :tool_counting_probe)

    OzMcp.Catalog.build!(Servers.Counting)

    assert Enum.sort(flush_probe()) == [:list, :template_list]
  end

  test "a static list is read at boot only, not at each request" do
    Process.register(self(), :tool_counting_probe)

    name = Module.concat(Servers.Counting, "T#{System.unique_integer([:positive])}")

    Utils.start_instance(Servers.Counting,
      name: name,
      resource_url: "https://mcp.example.com/mcp"
    )

    context = OzMcp.Context.new(name, :http_streamable, :rpc)
    flush_probe()

    {items, cursor} = OzMcp.Handler.Page.list(context, :tools, 2)
    assert Enum.map(items, & &1.name) == ["plain1", "plain2"]
    assert cursor == OzMcp.Utils.Paginate.encode_cursor(:tools, 2)

    assert flush_probe() == []
  end

  # The list of a page answers with the map that the build of each struct
  # gave, never with the struct: the builder of the result takes the map.
  # The plain path and the filtered path give the same answer for the same
  # principal.
  #
  test "the items of a list page are the built maps of the structs" do
    name =
      Module.concat(Servers.ScopedPaginated, "T#{System.unique_integer([:positive])}")

    Utils.start_instance(Servers.ScopedPaginated,
      name: name,
      resource_url: "https://mcp.example.com/mcp"
    )

    context = OzMcp.Context.new(name, :http_streamable, :rpc)

    principal =
      OzMcp.Auth.Principal.new!(subject: "lists-test", scopes: ["files:write", "admin"])

    {pairs, nil} =
      OzMcp.Auth.Listing.page(Servers.ScopedPaginated, :tools, principal, nil, 1)

    expected = Enum.map(pairs, fn {_struct, wire} -> wire end)

    assert expected != []
    assert Enum.all?(expected, fn item -> is_map(item) and not is_struct(item) end)

    # The plain path serves the catalog entries and the filtered path keeps
    # every tool that the principal can use: this principal holds all the
    # scopes, so the two answers are equal. Both give built maps.
    #
    assert OzMcp.Handler.Page.list(context, :tools, nil) == {expected, nil}

    assert OzMcp.Handler.Page.list(%{context | principal: principal}, :tools, nil) ==
             {expected, nil}
  end

  # The run function, the kind, the key of the result and the meta and
  # extras functions of each list of ListsForms.FullServer.
  #
  @full_lists [
    {&OzMcp.Handler.Lists.tools/2, :tools, :tools, OzMcp.Structs.Tool, :list_tools_result_meta,
     :list_tools_result_extras},
    {&OzMcp.Handler.Lists.resources/2, :resources, :resources, OzMcp.Structs.Resource,
     :list_resources_result_meta, :list_resources_result_extras},
    {&OzMcp.Handler.Lists.templates/2, :templates, :resourceTemplates,
     OzMcp.Structs.ResourceTemplate, :list_resource_templates_result_meta,
     :list_resource_templates_result_extras},
    {&OzMcp.Handler.Lists.prompts/2, :prompts, :prompts, OzMcp.Structs.Prompt,
     :list_prompts_result_meta, :list_prompts_result_extras}
  ]

  test "each static list answers like the build of today, for the four kinds" do
    {name, _session} = start(ListsForms.FullServer)
    context = OzMcp.Context.new(name, :http_streamable, :rpc)

    for {run, kind, key, struct, meta, extras} <- @full_lists do
      assert {{:rpc_success, response}, nil} = run.(context, nil)
      new = JSON.decode!(Wire.encode_answer(response))

      wires = OzMcp.Auth.Listing.read_wires(ListsForms.FullServer, kind)

      today =
        OzMcp.Utils.JsonRpc.success(
          context.rpc_id,
          OzMcp.Structs.Builder.page(
            key,
            struct,
            wires,
            nil,
            apply(ListsForms.FullServer, meta, []),
            apply(ListsForms.FullServer, extras, [])
          )
        )

      assert new == JSON.decode!(Wire.encode_answer(today)),
             "the answer of #{key} is not the one of today"
    end
  end

  test "the _meta and the extras of the list result are in the answer of the bytes" do
    {name, session} = start(ListsForms.FullServer)

    assert %{"result" => result} = answer(name, session, "tools/list")

    assert result["_meta"] == ListsForms.FullServer.list_tools_result_meta()
    assert result["list_extra"] == "extra value"
    assert Enum.map(result["tools"], & &1["name"]) == ["full"]
  end

  test "an extra with the key of the list is dropped before the bytes go in" do
    result =
      OzMcp.Structs.Builder.page(
        :tools,
        OzMcp.Structs.Tool,
        [],
        nil,
        nil,
        %{"tools" => "dropped", "free" => 1}
      )
      |> Map.put(:tools, [{:oz_mcp_json, "{}"}])

    assert result == %{:tools => [{:oz_mcp_json, "{}"}], "free" => 1}
  end

  test "a paginated list, a cursor and a filtered list keep the path of today" do
    {paginated, _session} = start(Servers.Paginates)
    context = OzMcp.Context.new(paginated, :http_streamable, :rpc)

    assert OzMcp.Handler.Page.encoded(
             context,
             :tools,
             Servers.Paginates.paginate_tools()
           ) ==
             :none

    {full, _session} = start(ListsForms.FullServer)
    cursor = %{OzMcp.Context.new(full, :http_streamable, :rpc) | rpc_params: %{"cursor" => "x"}}

    assert OzMcp.Handler.Page.encoded(cursor, :tools, nil) == :none

    principal = OzMcp.Auth.Principal.new!(subject: "lists-test", scopes: [])

    scoped = Module.concat(Servers.StructScoped, "T#{System.unique_integer([:positive])}")

    Utils.start_instance(Servers.StructScoped,
      name: scoped,
      resource_url: "https://mcp.example.com/mcp"
    )

    filtered = %{OzMcp.Context.new(scoped, :http_streamable, :rpc) | principal: principal}

    assert OzMcp.Handler.Page.encoded(filtered, :tools, nil) == :none
  end

  test "the pages of three static modules follow the declared order" do
    {name, session} = start(ListsForms.OrderedServer)

    first = answer(name, session, "tools/list")["result"]
    second = answer(name, session, "tools/list", %{"cursor" => first["nextCursor"]})["result"]
    third = answer(name, session, "tools/list", %{"cursor" => second["nextCursor"]})["result"]

    assert Enum.map(first["tools"], & &1["name"]) == ["full"]
    assert Enum.map(second["tools"], & &1["name"]) == ["same_tool"]
    assert Enum.map(third["tools"], & &1["name"]) == ["vendor_tool"]
    refute Map.has_key?(third, "nextCursor")
  end

  test "the one static list of a kind keeps the declared order of the modules" do
    {name, session} = start(ListsForms.MixedServer)

    result = answer(name, session, "tools/list")["result"]

    assert Enum.map(result["tools"], & &1["name"]) == ["full", "same_tool", "vendor_tool"]
  end

  test "a cursor on a static server with no pagination still gives invalid cursor" do
    {name, session} = start(ListsForms.FullServer)

    assert %{"error" => %{"code" => -32602, "message" => "invalid cursor"}} =
             answer(name, session, "tools/list", %{"cursor" => "x"})
  end

  defp flush_probe(acc \\ []) do
    receive do
      message -> flush_probe([message | acc])
    after
      0 -> acc
    end
  end

  defp start(server) do
    name = Module.concat(server, "T#{System.unique_integer([:positive])}")
    Utils.start_instance(server, name: name)
    {name, Utils.create_session(name, initialized: true)}
  end

  defp answer(name, session, method, params \\ %{}) do
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
    conn = Runner.post(name, session, body)
    assert conn.status == 200
    :json.decode(conn.resp_body)
  end
end
