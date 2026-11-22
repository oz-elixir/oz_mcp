defmodule OzMcp.Auth.ListingTest do
  use ExUnit.Case, async: true

  alias OzMcp.Auth.{Listing, Principal}
  alias Support.Servers

  # The scoped server serves two tool modules: Support.Entities.Tools.ScopedTest (read_file,
  # write_file [files:write], admin_tool [files:write, admin]) and
  # Support.Entities.Tools.SecondTest (get_date, get_time), plus one module for each of the
  # three other kinds. The paginated scoped server adds a resource module
  # with `dsl?: false` that returns plain maps.
  #
  defp principal(scopes), do: Principal.new!(subject: "listing-test", scopes: scopes)

  # Each item of a page is a pair of the struct and the map that its build
  # gave. The tests read the struct; the map travels to the answer.
  #
  defp structs(pairs), do: Enum.map(pairs, fn {struct, _wire} -> struct end)

  defp names(pairs), do: pairs |> structs() |> Enum.map(& &1.name)

  describe "filter?/2" do
    test "true for a kind where a module declares required scopes" do
      assert Listing.filter?(Servers.Scoped, :tools)
      assert Listing.filter?(Servers.Scoped, :resources)
      assert Listing.filter?(Servers.Scoped, :templates)
      assert Listing.filter?(Servers.Scoped, :prompts)
    end

    test "true for a dsl?: false module whose structs carry required_scopes" do
      assert Listing.filter?(Servers.StructScoped, :tools)
    end

    test "false for a kind with no scoped module, also with a dsl?: false module" do
      refute Listing.filter?(Servers.Counting, :tools)
    end

    test "false for a kind with no block" do
      refute Listing.filter?(Servers.Counting, :prompts)
    end
  end

  describe "page/5 for tools" do
    test "a principal with no scope sees only the tools that need no scope, in module order" do
      {items, max_page} = Listing.page(Servers.Scoped, :tools, principal([]), nil, 1)

      assert names(items) == ["read_file", "get_date", "get_time"]
      assert max_page == nil
    end

    test "a principal with every scope sees all the tools, in module order" do
      {items, _max_page} =
        Listing.page(Servers.Scoped, :tools, principal(["files:write", "admin"]), nil, 1)

      assert names(items) == ["read_file", "write_file", "admin_tool", "get_date", "get_time"]
    end

    test "the pages are full and the last page number counts the visible items" do
      writable = principal(["files:write"])

      {page1, max_page} = Listing.page(Servers.Scoped, :tools, writable, 2, 1)
      assert names(page1) == ["read_file", "write_file"]
      assert max_page == 2

      {page2, max_page} = Listing.page(Servers.Scoped, :tools, writable, 2, 2)
      assert names(page2) == ["get_date", "get_time"]
      assert max_page == 2

      {beyond, max_page} = Listing.page(Servers.Scoped, :tools, writable, 2, 3)
      assert beyond == []
      assert max_page == 2
    end
  end

  describe "page/5 for the other kinds" do
    test "a resource is visible when the principal holds the scopes of its uri" do
      {pairs, _} = Listing.page(Servers.Scoped, :resources, principal([]), nil, 1)
      assert Enum.map(structs(pairs), & &1.uri) == ["file:///public.md"]

      {pairs, _} =
        Listing.page(Servers.Scoped, :resources, principal(["files:write"]), nil, 1)

      assert Enum.map(structs(pairs), & &1.uri) == ["file:///public.md", "file:///secret.md"]
    end

    test "a template is visible when the principal holds its scopes" do
      {pairs, _} = Listing.page(Servers.Scoped, :templates, principal([]), nil, 1)
      assert pairs == []

      {pairs, _} =
        Listing.page(Servers.Scoped, :templates, principal(["files:write"]), nil, 1)

      assert Enum.map(structs(pairs), & &1.uriTemplate) == ["file:///docs/{name}"]
    end

    test "a prompt is visible when the principal holds its scopes" do
      {pairs, _} = Listing.page(Servers.Scoped, :prompts, principal([]), nil, 1)
      assert names(pairs) == ["summarize"]

      {pairs, _} =
        Listing.page(Servers.Scoped, :prompts, principal(["files:write"]), nil, 1)

      assert names(pairs) == ["summarize", "audit"]
    end
  end

  describe "page/5 with plain maps" do
    test "a plain map from a module with dsl?: false is built and always visible" do
      {pairs, _} =
        Listing.page(Servers.ScopedPaginated, :resources, principal([]), nil, 1)

      assert Enum.map(structs(pairs), & &1.uri) == [
               "file:///public.md",
               "file:///plain-one.md",
               "file:///plain-two.md"
             ]

      assert Enum.all?(pairs, fn {item, _wire} -> match?(%OzMcp.Structs.Resource{}, item) end)
    end

    test "the pages of the maps stay full and the last page counts the visible items" do
      {page1, max_page} =
        Listing.page(Servers.ScopedPaginated, :resources, principal([]), 2, 1)

      assert Enum.map(structs(page1), & &1.uri) == ["file:///public.md", "file:///plain-one.md"]
      assert max_page == 2

      {page2, max_page} =
        Listing.page(Servers.ScopedPaginated, :resources, principal([]), 2, 2)

      assert Enum.map(structs(page2), & &1.uri) == ["file:///plain-two.md"]
      assert max_page == 2
    end
  end

  describe "page/5 for a kind with no block" do
    test "the page is empty" do
      assert Listing.page(Servers.Scoped, :no_such_kind, principal([]), nil, 1) ==
               {[], nil}
    end
  end
end
