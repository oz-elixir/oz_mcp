#
# The reads of the one list of each kind of the catalog and the page of
# a list (`tools`, `resources`, `templates` or `prompts`) that a
# principal can use.
#
# The catalog holds one list for each kind, made at boot. The scope
# filter reads the struct, so the filtered list travels as pairs and the
# plain list as wire maps. A map entity carries `required_scopes` like a
# struct; the key never reaches the client.
#
# A list is filtered only when `filter?/2` is true: a server with no
# scoped entity of the kind never reads a whole list for one page.
#
defmodule OzMcp.Auth.Listing do
  @moduledoc false

  alias OzMcp.Auth.{Principal, Scopes}
  alias OzMcp.Catalog
  alias OzMcp.Utils.Paginate

  @type kind :: :tools | :resources | :templates | :prompts

  # True when the list of `kind` can change for a principal: the catalog
  # of the server holds the scopes of an entity of the kind (a struct
  # entity carries them in its field `required_scopes`, whatever form
  # the module gave).
  #
  # The catalog is read, `list/0` is not called. When the answer is
  # `false`, the caller keeps the plain path, which reads the stored list
  # of the kind.
  #
  @spec filter?(module(), kind()) :: boolean()
  def filter?(server, kind), do: Scopes.declared(server, kind) != []

  # The items of page `page` that `principal` can use and the number of
  # the last page. With no page size (`nil`), all the visible items and
  # `nil`.
  #
  @spec page(module(), kind(), Principal.t(), pos_integer() | nil, pos_integer()) ::
          {[{struct(), map()}], non_neg_integer() | nil}
  def page(server, kind, %Principal{} = principal, page_size, page) do
    server
    |> read(kind)
    |> Enum.filter(fn {struct, _wire} -> Scopes.visible?(struct, principal) end)
    |> cut(page_size, page)
  end

  @doc false
  @spec read(module(), kind()) :: [{struct(), map()}]
  def read(server, kind),
    do: server |> Catalog.fetch() |> Catalog.ordered(kind) |> Map.fetch!(:pairs)

  @doc false
  @spec read_wires(module(), kind()) :: [map()]
  def read_wires(server, kind),
    do: server |> Catalog.fetch() |> Catalog.ordered(kind) |> Map.fetch!(:wires)

  # The one list of the boot as bytes. nil: a kind with no entry, or whose
  # encode failed, is read as wire maps.
  #
  @doc false
  @spec read_encoded(module(), kind()) :: nil | [{:oz_mcp_json, binary()}]
  def read_encoded(server, kind) do
    case Catalog.encoded(Catalog.fetch(server), kind) do
      nil -> nil
      bytes -> [{:oz_mcp_json, bytes}]
    end
  end

  defp cut(items, nil, _page), do: {items, nil}

  defp cut(items, size, page) do
    {Enum.slice(items, (page - 1) * size, size), Paginate.max_page(length(items), size)}
  end
end
