defmodule OzMcp.Handler.Page do
  @moduledoc false

  alias OzMcp.Auth.{Gate, Listing}
  alias OzMcp.Catalog
  alias OzMcp.Context

  # The answer holds the map that the build of each entity gave. The one
  # list of a kind gives the wire maps of the boot, with no map at the
  # request; the filtered path maps its page, cut after the filter.
  #
  @spec list(Context.t(), :tools | :resources | :templates | :prompts, pos_integer() | nil) ::
          {[map()] | nil, String.t() | nil}
  def list(context, kind, page_size) do
    if scoped?(context, kind),
      do: scoped_page(context, kind, page_size),
      else: plain_page(context, kind, page_size)
  end

  # The bytes of the boot, for a list with no page size, no cursor and
  # no scope filter. Any other request keeps the path of `list/3`: the
  # cursor must give -32602 and the filter must read the structs.
  #
  @spec encoded(Context.t(), :tools | :resources | :templates | :prompts, pos_integer() | nil) ::
          :none | {:encoded, [{:oz_mcp_json, binary()}]}
  def encoded(context, kind, nil) do
    if cursor_given?(context.rpc_params) or scoped?(context, kind) do
      :none
    else
      case Listing.read_encoded(context.server, kind) do
        nil -> :none
        items -> {:encoded, items}
      end
    end
  end

  def encoded(_context, _kind, _page_size), do: :none

  # The cursor of the list methods is an opaque string that carries the kind
  # and the page (see OzMcp.Utils.Paginate). A cursor that decodes to a page
  # after the last page is invalid too: the caller answers a -32602 error.
  #
  defp page_from_cursor(nil, _kind), do: {:ok, 1}

  defp page_from_cursor(rpc_params, kind) do
    case Map.get(rpc_params, "cursor") do
      nil -> {:ok, 1}
      cursor -> OzMcp.Utils.Paginate.decode_cursor(kind, cursor)
    end
  end

  # A list with no pagination never gives a cursor, so any cursor is forged.
  #
  defp cursor_given?(nil), do: false

  defp cursor_given?(rpc_params), do: Map.get(rpc_params, "cursor") != nil

  # The plain path reads the catalog: the one list of a kind gives the
  # wire maps of the boot, with no map at the request. The clause with no
  # page size refuses a cursor in the request, before the catalog is read.
  #
  defp plain_page(context, kind, nil) do
    if cursor_given?(context.rpc_params) do
      {nil, nil}
    else
      {Listing.read_wires(context.server, kind), nil}
    end
  end

  defp plain_page(context, kind, page_size) do
    %{wires: wires, count: count} = context.server |> Catalog.fetch() |> Catalog.ordered(kind)

    case page_from_cursor(context.rpc_params, kind) do
      {:ok, page} ->
        max_page = OzMcp.Utils.Paginate.max_page(count, page_size)

        if page > max(max_page, 1) do
          {nil, nil}
        else
          next = if page < max_page, do: OzMcp.Utils.Paginate.encode_cursor(kind, page + 1)
          {Enum.slice(wires, (page - 1) * page_size, page_size), next}
        end

      :error ->
        {nil, nil}
    end
  end

  # A protected server filters a list by scope when the author did not turn
  # it off in the authorization block and when the list can change (see
  # Listing.filter?/2). No principal means an open server.
  #
  defp scoped?(%{principal: nil}, _kind), do: false

  defp scoped?(context, kind) do
    case Gate.fetch_config(context.instance, context.config) do
      {:ok, %{} = auth} ->
        Map.get(auth, :filter_by_scope, true) and Listing.filter?(context.server, kind)

      _none ->
        false
    end
  end

  # The filtered path reads the stored list of the kind, keeps the entities the
  # principal can use and cuts the page after the filter, so each page is
  # full and the cursor counts the filtered items.
  #
  defp scoped_page(context, kind, page_size) do
    case scoped_page_number(context.rpc_params, kind, page_size) do
      {:ok, page} ->
        {pairs, max_page} =
          Listing.page(context.server, kind, context.principal, page_size, page)

        wires = Enum.map(pairs, fn {_struct, wire} -> wire end)

        cond do
          is_nil(max_page) -> {wires, nil}
          page > max(max_page, 1) -> {nil, nil}
          page < max_page -> {wires, OzMcp.Utils.Paginate.encode_cursor(kind, page + 1)}
          true -> {wires, nil}
        end

      :error ->
        {nil, nil}
    end
  end

  defp scoped_page_number(rpc_params, _kind, nil) do
    if cursor_given?(rpc_params), do: :error, else: {:ok, 1}
  end

  defp scoped_page_number(rpc_params, kind, _page_size), do: page_from_cursor(rpc_params, kind)
end
