defmodule OzMcp.Utils.PaginateTest do
  use ExUnit.Case, async: true

  alias OzMcp.Utils.Paginate

  # -----------------------------------------------------------------------
  # max_page/2
  # -----------------------------------------------------------------------

  describe "max_page/2" do
    test "returns 0 when total is 0" do
      assert Paginate.max_page(0, 4) == 0
    end

    test "returns 1 when total fits in one page" do
      assert Paginate.max_page(4, 4) == 1
      assert Paginate.max_page(3, 4) == 1
    end

    test "returns the ceiling of total divided by page size" do
      #
      # Reference case from tmp/mcp_ex: counts 3 + 3 + 5 = 11 items
      #
      assert Paginate.max_page(11, 4) == 3
      assert Paginate.max_page(12, 4) == 3
      assert Paginate.max_page(13, 4) == 4
    end

    test "returns one page per item when page size is 1" do
      assert Paginate.max_page(5, 1) == 5
    end
  end

  # -----------------------------------------------------------------------
  # encode_cursor/2 and decode_cursor/2
  # -----------------------------------------------------------------------

  describe "encode_cursor/2 and decode_cursor/2" do
    test "a round trip gives the page back" do
      for kind <- [:tools, :resources, :templates, :prompts] do
        for page <- [1, 3, 42] do
          cursor = Paginate.encode_cursor(kind, page)
          assert is_binary(cursor)
          assert not String.contains?(cursor, "=")
          assert Paginate.decode_cursor(kind, cursor) == {:ok, page}
        end
      end
    end

    test "a cursor of another kind is refused" do
      cursor = Paginate.encode_cursor(:tools, 2)
      assert Paginate.decode_cursor(:resources, cursor) == :error
    end

    test "a decimal page number is refused" do
      assert Paginate.decode_cursor(:tools, "2") == :error
      assert Paginate.decode_cursor(:tools, "42") == :error
    end

    test "a page with a sign or a space is refused" do
      #
      # Integer.parse accepts "+3": the strict compare with the encoding
      # refuses it.
      #
      for raw <- ["+3", " 3", "3 ", "3x", "3.5"] do
        cursor = Base.url_encode64("oz1:tools:#{raw}", padding: false)
        assert Paginate.decode_cursor(:tools, cursor) == :error, "cursor: #{raw}"
      end
    end

    test "a page of zero or less is refused" do
      for raw <- ["0", "-1"] do
        cursor = Base.url_encode64("oz1:tools:#{raw}", padding: false)
        assert Paginate.decode_cursor(:tools, cursor) == :error
      end
    end

    test "a cursor of another version is refused" do
      cursor = Base.url_encode64("oz2:tools:3", padding: false)
      assert Paginate.decode_cursor(:tools, cursor) == :error
    end

    test "a raw value that is not of the shape version:kind:page is refused" do
      for raw <- ["", "oz1", "oz1:tools", "oz1:tools:3:4", "oz1::3"] do
        cursor = Base.url_encode64(raw, padding: false)
        assert Paginate.decode_cursor(:tools, cursor) == :error, "cursor: #{raw}"
      end
    end

    test "a value that is not base64url is refused" do
      assert Paginate.decode_cursor(:tools, "abc") == :error
      assert Paginate.decode_cursor(:tools, "") == :error
    end

    test "a padded encoding is refused" do
      padded = Base.url_encode64("oz1:tools:3", padding: true)
      assert String.contains?(padded, "=")
      assert Paginate.decode_cursor(:tools, padded) == :error
    end

    test "a cursor over the size limit is refused" do
      cursor = String.duplicate("a", 65)
      assert Paginate.decode_cursor(:tools, cursor) == :error
    end

    test "a non binary cursor is refused" do
      assert Paginate.decode_cursor(:tools, 3) == :error
      assert Paginate.decode_cursor(:tools, nil) == :error
    end
  end
end
