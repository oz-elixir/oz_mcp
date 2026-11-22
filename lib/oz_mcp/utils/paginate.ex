#
# The page count and the cursors of the list methods.
#
defmodule OzMcp.Utils.Paginate do
  @moduledoc false

  @spec max_page(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def max_page(total, page_size) do
    div(total + page_size - 1, page_size)
  end

  # -------------------------------------------------------------------
  # Cursors of the list methods
  # -------------------------------------------------------------------

  # The specification asks for an opaque string, not for a secret: a
  # forged cursor can only reach a page that a valid cursor reaches too.
  # The decoder is strict (it re-encodes the page and compares), so a
  # cursor of another kind, of another version, or with a decoration
  # (a sign, a space, padding) is refused.
  #
  @cursor_version "oz1"

  # A valid cursor is short. The limit stops a parse of a very long number.
  #
  @max_cursor_bytes 64

  @doc false
  @spec encode_cursor(atom(), pos_integer()) :: String.t()
  def encode_cursor(kind, page) when is_atom(kind) and is_integer(page) and page > 0 do
    Base.url_encode64("#{@cursor_version}:#{kind}:#{page}", padding: false)
  end

  @doc false
  @spec decode_cursor(atom(), term()) :: {:ok, pos_integer()} | :error
  def decode_cursor(kind, cursor)
      when is_binary(cursor) and byte_size(cursor) <= @max_cursor_bytes do
    with {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         [@cursor_version, kind_name, page_text] <- String.split(raw, ":"),
         true <- kind_name == Atom.to_string(kind),
         {page, ""} when page > 0 <- Integer.parse(page_text),
         true <- encode_cursor(kind, page) == cursor do
      {:ok, page}
    else
      _ -> :error
    end
  end

  def decode_cursor(_kind, _cursor), do: :error
end
