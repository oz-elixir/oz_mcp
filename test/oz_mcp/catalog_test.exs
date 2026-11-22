#
# Tests for OzMcp.Catalog: the server-wide structure of the entities,
# read one time at boot.
# See: lib/oz_mcp/catalog.ex
#
defmodule CatalogTest.RaisingList do
  use OzMcp.Config.Tool, dsl?: false, warn?: false

  @impl true
  def list, do: raise("list/0 raises")

  @impl true
  def call(_ctx, _params), do: {:ok, %{"content" => []}}
end

defmodule CatalogTest.BadSchema do
  use OzMcp.Config.Tool, dsl?: false

  @tool %{
    "name" => "bad_schema",
    "inputSchema" => %{"type" => "object", "properties" => %{"price" => %{"type" => "float"}}}
  }

  @impl true
  def list, do: [@tool]

  @impl true
  def call(_ctx, _params), do: {:ok, %{"content" => []}}
end

defmodule CatalogTest.BadSchemaStruct do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.Tool

  @impl true
  def list do
    schema = %{"type" => "object", "properties" => %{"price" => %{"type" => "float"}}}
    tool = %Tool{} |> Tool.name("bad_struct") |> Tool.input_schema(schema)

    [tool]
  end

  @impl true
  def call(_ctx, _params), do: {:ok, %{"content" => []}}
end

defmodule CatalogTest.BadField do
  use OzMcp.Config.Tool, dsl?: false, warn?: false

  @tool %{"description" => "A tool with no name", "inputSchema" => %{"type" => "object"}}

  @impl true
  def list, do: [@tool]

  @impl true
  def call(_ctx, _params), do: {:ok, %{"content" => []}}
end

defmodule CatalogTest.NotJson do
  use OzMcp.Config.Tool, dsl?: false, warn?: false

  @impl true
  def list, do: [%{name: "not_json", extras: %{"ref" => make_ref()}}]

  @impl true
  def call(_ctx, _params), do: {:ok, %{"content" => []}}
end

defmodule CatalogTest.ImproperIcons do
  use OzMcp.Config.Tool, dsl?: false, warn?: false

  @tool %{
    "name" => "improper_icons",
    "description" => "A tool whose icons are not a proper list",
    "inputSchema" => %{"type" => "object"},
    "icons" => [1 | 2]
  }

  @impl true
  def list, do: [@tool]

  @impl true
  def call(_ctx, _params), do: {:ok, %{"content" => []}}
end

#
# A static tool whose input schema has a `pattern`. On OTP 28 the compiled
# regex holds a reference, so 2 builds of its root are not equal.
#
defmodule CatalogTest.PatternSchema do
  use OzMcp.Config.Tool, dsl?: false

  @tool %{
    "name" => "pattern",
    "inputSchema" => %{
      "type" => "object",
      "properties" => %{"code" => %{"type" => "string", "pattern" => "^[A-Z]+$"}}
    }
  }

  @impl true
  def list, do: [@tool]

  @impl true
  def call(_ctx, _params), do: {:ok, %{"content" => []}}
end

#
# A static tool module whose list returns a map with a string
# required_scopes key. The module defines no constant.
#
defmodule CatalogTest.ScopedMapTool do
  use OzMcp.Config.Tool, dsl?: false, warn?: false

  @tool %{
    "name" => "scoped_map",
    "description" => "A map tool with scopes",
    "inputSchema" => %{"type" => "object"},
    "required_scopes" => ["tools:write"]
  }

  @impl true
  def list, do: [@tool]

  @impl true
  def call(_ctx, _params), do: {:ok, %{"content" => []}}
end

#
# A static tool module whose list returns a struct with scopes and no
# constant.
#
defmodule CatalogTest.ScopedStructTool do
  use OzMcp.Config.Tool, dsl?: false, warn?: false

  alias OzMcp.Structs.Tool

  @impl true
  def list do
    tool =
      %Tool{}
      |> Tool.name("scoped_struct")
      |> Tool.input_schema(%{type: "object"})
      |> Tool.required_scopes(["tools:read"])

    [tool]
  end

  @impl true
  def call(_ctx, _params), do: {:ok, %{"content" => []}}
end

#
# A static resource module whose uri the tests change. A relative uri
# stops the boot; the absolute value boots.
#
defmodule CatalogTest.RelativeUriStructResources do
  use OzMcp.Config.Resource, dsl?: false

  @impl true
  def list, do: resources()

  @impl true
  def read(_ctx, _params), do: {:error, :not_found}

  def put(uri) do
    resource = %OzMcp.Structs.Resource{uri: uri, name: "notes"}
    :persistent_term.put({__MODULE__, :resource}, resource)
  end

  defp resources, do: [:persistent_term.get({__MODULE__, :resource}, default())]

  defp default, do: %OzMcp.Structs.Resource{uri: "file:///notes/1", name: "notes"}
end

#
# The same list as the struct module, with the string-key map form.
#
defmodule CatalogTest.RelativeUriMapResources do
  use OzMcp.Config.Resource, dsl?: false

  @impl true
  def list, do: resources()

  @impl true
  def read(_ctx, _params), do: {:error, :not_found}

  def put(uri), do: :persistent_term.put({__MODULE__, :uri}, uri)

  defp resources,
    do: [
      %{"uri" => :persistent_term.get({__MODULE__, :uri}, "file:///notes/1"), "name" => "notes"}
    ]
end

for {module, name, uri_template} <- [
      {CatalogTest.OpenSchemeTemplates, "open scheme", "{scheme}://x"},
      {CatalogTest.OpenUriTemplates, "open uri", "{+uri}"},
      {CatalogTest.UpperSchemeTemplates, "upper scheme", "FILE://docs/{path}"},
      {CatalogTest.BadTemplate, "bad", "file:///{name*}"}
    ] do
  defmodule module do
    use OzMcp.Config.Template, dsl?: false

    @templates [%{"name" => name, "uriTemplate" => uri_template}]

    @impl true
    def list, do: @templates

    @impl true
    def read(_ctx, _params, _uri_template, _uri_params), do: {:ok, %{}}
  end
end

defmodule OzMcp.CatalogTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Support.Factories.Server

  alias CatalogTest.{
    BadField,
    BadSchema,
    BadSchemaStruct,
    BadTemplate,
    ImproperIcons,
    NotJson,
    OpenSchemeTemplates,
    OpenUriTemplates,
    PatternSchema,
    RaisingList,
    RelativeUriMapResources,
    RelativeUriStructResources,
    UpperSchemeTemplates
  }

  alias OzMcp.Auth.Listing
  alias OzMcp.Catalog
  alias OzMcp.Wire
  alias Support.Helpers.Utils

  require Support.Factories.Tool

  @template_modules [
    Support.Entities.Templates.FirstTest,
    Support.Entities.Templates.DslTest.Multiple,
    UpperSchemeTemplates,
    OpenSchemeTemplates,
    OpenUriTemplates
  ]

  @template_uris [
    "file://docs/intro.md",
    "FILE://docs/intro.md",
    "file://docs/a/b.md",
    "db://user/42",
    "file://x",
    "custom://x",
    "mailto:someone@example.com",
    "unknown://nothing"
  ]

  defp server do
    module "Catalog" do
      tools do
        tool Support.Entities.Tools.DslTest.Multiple
        tool Support.Entities.Tools.SecondTest
        tool Support.Entities.Tools.CountingTest
      end

      prompts do
        prompt Support.Entities.Prompts.DslTest.Multiple
        prompt Support.Entities.Prompts.FirstTest
      end

      resources do
        resource Support.Entities.Resources.DslTest.Multiple
        resource Support.Entities.Resources.PlainMapTest
      end
    end
    |> compile()
  end

  defp pattern_server do
    module "CatalogPattern" do
      tools do
        tool PatternSchema
      end
    end
    |> compile()
  end

  defp template_server(modules) do
    exprs = [
      Support.Factories.Server.__templates__(
        [],
        Enum.map(modules, &Support.Factories.Server.template/1)
      )
    ]

    "CatalogTemplates"
    |> Support.Factories.Server.__module__([_tools_: :_none_], exprs)
    |> Support.Factories.Server.compile()
  end

  # A static tool module whose list returns a map with the given scopes.
  # The module defines no constant, so only the catalog can hold them.
  #
  defp scoped_map_tool(scopes) do
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

    Support.Factories.Tool.module("ScopedMapTool", _dsl_: false, _code_: code)
    |> Support.Factories.Tool.compile()
  end

  defp scoped_map_server(tool_module) do
    exprs = [Support.Factories.Server.__tools__([], [Support.Factories.Server.tool(tool_module)])]

    "CatalogScopes"
    |> Support.Factories.Server.__module__([_tools_: :_none_], exprs)
    |> Support.Factories.Server.compile()
  end

  describe "scopes of the static entities" do
    test "the catalog stores the scopes of a map entity and of a struct entity" do
      server =
        module "CatalogScopesData" do
          tools do
            tool CatalogTest.ScopedMapTool
            tool CatalogTest.ScopedStructTool
          end
        end
        |> compile()

      catalog = Catalog.build!(server)

      assert Catalog.required_scopes(catalog, :tools) == ["tools:read", "tools:write"]
      assert Catalog.required_scopes(catalog, :prompts) == []
      assert Catalog.required_scopes(catalog, :resources) == []
      assert Catalog.required_scopes(catalog, :templates) == []
    end

    test "the entity of a scoped map tool keeps the checked scopes" do
      server = scoped_map_server(scoped_map_tool(["tools:write", "tools:write"]))

      {_module, entry} = Catalog.build!(server).tools |> Map.fetch!("scoped_map")

      assert entry.entity.required_scopes == ["tools:write"]
    end

    test "a bad required_scopes of a map stops the build" do
      for bad <- [[], "a"] do
        server = scoped_map_server(scoped_map_tool(bad))

        assert_raise ArgumentError, ~r/'required_scopes'/, fn -> Catalog.build!(server) end
      end
    end
  end

  describe "build!/1" do
    test "gives the same module and entity as a full walk, for each name" do
      server = server()
      catalog = Catalog.build!(server)

      names = ["first", "second", "get_date", "get_time", "plain1", "plain5", "unknown"]

      Enum.each(names, fn name ->
        assert Catalog.find_tool(catalog, name) ==
                 Support.Helpers.CatalogWalk.find_tool(server, name)
      end)

      prompts = ["first", "second", "code_review", "unknown"]

      Enum.each(prompts, fn name ->
        assert Catalog.find_prompt(catalog, name) ==
                 Support.Helpers.CatalogWalk.find_prompt(server, name)
      end)

      resources = [
        "file:///first.md",
        "file:///second.md",
        "file:///plain-one.md",
        "file:///marketing.md",
        "file:///unknown.md"
      ]

      Enum.each(resources, fn uri ->
        assert Catalog.find_resource(catalog, uri) ==
                 Support.Helpers.CatalogWalk.find_resource(server, uri)
      end)
    end

    test "an unknown name gives nil" do
      catalog = Catalog.build!(server())

      assert Catalog.find_tool(catalog, "no_such_tool") == nil
      assert Catalog.find_prompt(catalog, "no_such_prompt") == nil
      assert Catalog.find_resource(catalog, "file:///no_such_resource.md") == nil
    end

    test "a module with a list/0 that raises stops the build" do
      server =
        module "CatalogRaisingList" do
          tools do
            tool RaisingList
          end
        end
        |> compile()

      assert_raise RuntimeError, "list/0 raises", fn ->
        Catalog.build!(server)
      end
    end

    test "a static module gives one entry per item of list/0, in the same order" do
      for {module, kind} <- [
            {Support.Entities.Tools.SecondTest, :tools},
            {Support.Entities.Tools.CountingTest, :tools},
            {Support.Entities.Resources.FirstTest, :resources},
            {Support.Entities.Resources.PlainMapTest, :resources}
          ] do
        entries = Catalog.entries(module, kind)

        structs =
          Enum.map(module.list(), fn item ->
            {:ok, struct} = OzMcp.Catalog.Normalize.entity(kind, item)
            struct
          end)

        assert Enum.map(entries, & &1.entity) == structs
      end
    end

    test "a find of a map entity gives a struct" do
      catalog = Catalog.build!(server())

      assert {Support.Entities.Tools.CountingTest, %OzMcp.Structs.Tool{name: "plain2"}} =
               Catalog.find_tool(catalog, "plain2")

      assert {Support.Entities.Resources.PlainMapTest,
              %OzMcp.Structs.Resource{uri: "file:///plain-two.md"}} =
               Catalog.find_resource(catalog, "file:///plain-two.md")
    end
  end

  describe "the ordered list" do
    test "a kind holds one list with the pairs, the wires and the count made at build" do
      catalog = Catalog.build!(server())
      assert %{pairs: pairs, wires: wires, count: count} = Catalog.ordered(catalog, :tools)

      assert count == length(pairs)
      assert length(wires) == count

      assert Enum.all?(Enum.zip(pairs, wires), fn {{struct, wire}, wire_map} ->
               match?(%OzMcp.Structs.Tool{}, struct) and
                 wire == wire_map and wire_map == OzMcp.Structs.Tool.build(struct)
             end)
    end

    test "read/2 and read_wires/2 give the stored lists of the build" do
      server = server()
      catalog = Catalog.build!(server)
      assert %{pairs: pairs, wires: wires} = Catalog.ordered(catalog, :tools)

      assert ^pairs = Listing.read(server, :tools)
      assert ^wires = Listing.read_wires(server, :tools)

      assert Enum.map(pairs, fn {struct, _wire} -> struct.name end) ==
               [
                 "first",
                 "second",
                 "get_date",
                 "get_time",
                 "plain1",
                 "plain2",
                 "plain3",
                 "plain4",
                 "plain5"
               ]
    end
  end

  describe "the encoded list" do
    test "a kind gives the inside of the array of its wire maps" do
      catalog = Catalog.build!(server())
      assert %{wires: wires} = Catalog.ordered(catalog, :tools)

      assert bytes = Catalog.encoded(catalog, :tools)
      refute String.starts_with?(bytes, "[")
      refute String.ends_with?(bytes, "]")

      assert {:ok, decoded} = Wire.decode("[" <> bytes <> "]")
      assert decoded == Enum.map(wires, &Wire.to_wire/1)

      # The server declares no templates: a kind with no entry has no
      # binary.
      #
      assert Catalog.encoded(catalog, :templates) == nil
    end
  end

  describe "find_template/2" do
    property "agrees with a full walk for random declarations and URIs" do
      #
      # `Enum.uniq/1`, not `uniq_list_of/2`: with 6 modules, the generator
      # gives up after 10 draws of a module already in the list.
      #
      check all modules <-
                  map(
                    list_of(member_of(@template_modules), min_length: 1, max_length: 4),
                    &Enum.uniq/1
                  ),
                uri <- member_of(@template_uris),
                max_runs: 25 do
        server = template_server(modules)
        catalog = Catalog.build!(server)

        assert Catalog.find_template(catalog, uri) ==
                 Support.Helpers.CatalogWalk.find_template(server, uri)
      end
    end

    test "the match is case-sensitive" do
      catalog =
        Catalog.build!(
          template_server([UpperSchemeTemplates, Support.Entities.Templates.FirstTest])
        )

      assert {Support.Entities.Templates.FirstTest, _, %{"path" => "intro.md"}} =
               Catalog.find_template(catalog, "file://docs/intro.md")

      assert {UpperSchemeTemplates, _, %{"path" => "intro.md"}} =
               Catalog.find_template(catalog, "FILE://docs/intro.md")
    end

    test "open templates match in the declared order" do
      server =
        template_server([
          OpenSchemeTemplates,
          Support.Entities.Templates.FirstTest,
          OpenUriTemplates
        ])

      catalog = Catalog.build!(server)

      assert {OpenSchemeTemplates, _, %{"scheme" => "file"}} =
               Catalog.find_template(catalog, "file://x")

      assert {Support.Entities.Templates.FirstTest, _, %{"path" => "intro.md"}} =
               Catalog.find_template(catalog, "file://docs/intro.md")

      assert {OpenUriTemplates, _, %{"uri" => "mailto:someone@example.com"}} =
               Catalog.find_template(catalog, "mailto:someone@example.com")
    end

    test "an unknown URI gives nil" do
      catalog = Catalog.build!(template_server([Support.Entities.Templates.FirstTest]))

      assert Catalog.find_template(catalog, "unknown://nothing") == nil
    end

    test "a static template with a bad template stops the build" do
      server = template_server([BadTemplate])

      assert_raise ArgumentError, ~r/invalid URI template/, fn -> Catalog.build!(server) end
    end
  end

  describe "find_template_by_ref/2" do
    test "agrees with a full walk of list/0" do
      server = template_server([Support.Entities.Templates.FirstTest, OpenUriTemplates])
      catalog = Catalog.build!(server)

      refs = [
        "file://docs/{path}",
        "{+uri}",
        "file://docs/{unknown}",
        "file://docs/intro.md"
      ]

      Enum.each(refs, fn ref ->
        assert Catalog.find_template_by_ref(catalog, ref) ==
                 Support.Helpers.CatalogWalk.find_template_by_ref(server, ref)
      end)
    end

    test "returns {module, template, %{}} for a static template" do
      catalog = Catalog.build!(template_server([Support.Entities.Templates.FirstTest]))

      assert {Support.Entities.Templates.FirstTest, %OzMcp.Structs.ResourceTemplate{} = template,
              %{}} =
               Catalog.find_template_by_ref(catalog, "file://docs/{path}")

      assert template.uriTemplate == "file://docs/{path}"
    end
  end

  describe "boot/1 and fetch/1" do
    test "fetch/1 with no boot builds and stores the catalog" do
      server = server()

      catalog = Catalog.fetch(server)

      assert %Catalog{} = catalog
      assert Catalog.fetch(server) === catalog
    end

    test "each static tool has its input root and its output root" do
      server =
        module "CatalogRoots" do
          tools do
            tool Support.Entities.Tools.DslTest.Full
            tool Support.Entities.Tools.FirstTest
            tool Support.Entities.Tools.CountingTest
          end
        end
        |> compile()

      catalog = Catalog.fetch(server)

      assert Map.has_key?(catalog.roots, {Support.Entities.Tools.DslTest.Full, "full", :input})
      assert Map.has_key?(catalog.roots, {Support.Entities.Tools.DslTest.Full, "full", :output})

      assert Map.has_key?(
               catalog.roots,
               {Support.Entities.Tools.FirstTest, "get_temperature", :input}
             )

      assert Map.has_key?(catalog.roots, {Support.Entities.Tools.CountingTest, "plain3", :input})
      refute Map.has_key?(catalog.roots, {Support.Entities.Tools.CountingTest, "plain3", :output})

      assert {:ok, %JSV.Root{}} =
               Catalog.fetch_root(
                 catalog,
                 Support.Entities.Tools.DslTest.Full,
                 "full",
                 :output,
                 %{}
               )
    end

    test "a bad input schema gives an error with the tool, the module and the kind" do
      server =
        module "CatalogBadSchema" do
          tools do
            tool BadSchema
          end
        end
        |> compile()

      assert_raise ArgumentError,
                   ~r/invalid input schema for tool "bad_schema" in CatalogTest\.BadSchema/,
                   fn -> Catalog.build!(server) end
    end

    test "a bad static map stops the boot with the module and the field" do
      server =
        module "CatalogBadField" do
          tools do
            tool BadField
          end
        end
        |> compile()

      assert_raise ArgumentError, ~r/CatalogTest\.BadField: tools: .*name/, fn ->
        Catalog.build!(server)
      end
    end

    test "a static map with a term that is not JSON stops the boot with the module and the path" do
      server =
        module "CatalogNotJson" do
          tools do
            tool NotJson
          end
        end
        |> compile()

      assert_raise ArgumentError,
                   ~r/CatalogTest\.NotJson: tools: the entry is not JSON at ref: #Reference/,
                   fn -> Catalog.build!(server) end
    end

    test "a static map whose icons are an improper list stops the boot and names the field" do
      server =
        module "CatalogImproperIcons" do
          tools do
            tool ImproperIcons
          end
        end
        |> compile()

      assert_raise ArgumentError,
                   ~r/CatalogTest\.ImproperIcons: tools: .*icons must be a list/,
                   fn ->
                     Catalog.build!(server)
                   end
    end

    test "a static resource with a relative uri stops the boot, as a struct and as a map" do
      RelativeUriStructResources.put("notes/1")
      RelativeUriMapResources.put("notes/1")

      struct_server =
        module "CatalogRelativeUriStruct" do
          resources do
            resource RelativeUriStructResources
          end
        end
        |> compile()

      assert_raise ArgumentError,
                   ~r/CatalogTest\.RelativeUriStructResources: resources: .*absolute URI/,
                   fn ->
                     Catalog.build!(struct_server)
                   end

      map_server =
        module "CatalogRelativeUriMap" do
          resources do
            resource RelativeUriMapResources
          end
        end
        |> compile()

      assert_raise ArgumentError,
                   ~r/CatalogTest\.RelativeUriMapResources: resources: .*absolute URI/,
                   fn ->
                     Catalog.build!(map_server)
                   end
    end

    test "the same static resource module boots with an absolute uri" do
      RelativeUriStructResources.put("file:///notes/1")
      RelativeUriMapResources.put("file:///notes/1")

      struct_server =
        module "CatalogRelativeUriStructGood" do
          resources do
            resource RelativeUriStructResources
          end
        end
        |> compile()

      map_server =
        module "CatalogRelativeUriMapGood" do
          resources do
            resource RelativeUriMapResources
          end
        end
        |> compile()

      assert Map.has_key?(Catalog.build!(struct_server).resources, "file:///notes/1")
      assert Map.has_key?(Catalog.build!(map_server).resources, "file:///notes/1")
    end

    test "a static tool with a bad schema stops the boot" do
      server =
        module "CatalogBadSchemaBoot" do
          tools do
            tool BadSchemaStruct
          end
        end
        |> compile()

      assert_raise ArgumentError, ~r/invalid input schema for tool "bad_struct"/, fn ->
        OzMcp.Instance.Config.parse!(server: server, allowed_origins: [])
      end
    end

    test "the instance config holds no catalog" do
      config = OzMcp.Instance.Config.parse!(server: server(), allowed_origins: [])

      refute Map.has_key?(config, :catalog)
    end

    test "two instances of one server read the same catalog" do
      server = server()

      Utils.start_instance(server)
      catalog = Catalog.fetch(server)

      Utils.start_instance(server)

      assert Catalog.fetch(server) === catalog
    end

    test "a second boot of a server with a pattern keeps the same roots" do
      server = pattern_server()

      first = Catalog.boot(server)
      second = Catalog.boot(server)

      assert first.roots == second.roots
      assert second === first
    end

    test "a second instance of a server with a pattern keeps the same roots" do
      server = pattern_server()

      Utils.start_instance(server)
      catalog = Catalog.fetch(server)

      Utils.start_instance(server)

      assert Catalog.fetch(server) === catalog
    end

    test "a changed catalog replaces the stored catalog" do
      server = server()
      :persistent_term.put({Catalog, server}, %{Catalog.build!(server) | tools: %{}})

      catalog = Catalog.boot(server)

      refute catalog.tools == %{}
      assert Catalog.fetch(server) === catalog
    end

    test "a stop of the instance keeps the catalog" do
      server = server()
      name = Module.concat(server, "CatalogStop")

      Utils.start_instance(server, name: name)
      catalog = Catalog.fetch(server)
      Utils.stop_instance(name)

      assert Catalog.fetch(server) === catalog
    end
  end
end
