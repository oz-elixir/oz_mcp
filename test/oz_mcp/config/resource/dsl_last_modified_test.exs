#
# Tests for the `last_modified/1` macro of the resource DSL.
# See: lib/oz_mcp/config/resource/dsl.ex
#
defmodule OzMcp.Config.Resource.DSLLastModifiedTest do
  use ExUnit.Case, async: true

  import Support.Factories.Resource

  describe "last_modified/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts 2025-01-12T15:00:58Z" do
      resource =
        module("LastModified") do
          resource("doc.md") do
            annotations do
              last_modified("2025-01-12T15:00:58Z")
            end
          end
        end
        |> compile_one_resource()

      assert resource.annotations.lastModified == "2025-01-12T15:00:58Z"
    end

    test "accepts an offset: 2025-01-12T15:00:58+02:00" do
      resource =
        module("LastModified") do
          resource("doc.md") do
            annotations do
              last_modified("2025-01-12T15:00:58+02:00")
            end
          end
        end
        |> compile_one_resource()

      assert resource.annotations.lastModified == "2025-01-12T15:00:58+02:00"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when last_modified is used multiple times" do
      module("LastModified") do
        resource("doc.md") do
          annotations(last_modified: "2025-01-01T00:00:00Z") do
            last_modified("2025-06-01T00:00:00Z")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'last_modified' multiple times")
    end

    test "raises when last_modified is not a string" do
      module("LastModified") do
        resource("doc.md") do
          annotations(last_modified: 123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'last_modified' must be a string, got: 123")
    end

    test "raises for a date with no time" do
      module("LastModified") do
        resource("doc.md") do
          annotations do
            last_modified("2025-01-12")
          end
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~r/'last_modified' must be an ISO 8601 date and time/
      )
    end

    test "raises for a time with no offset" do
      module("LastModified") do
        resource("doc.md") do
          annotations do
            last_modified("2025-01-12T15:00:58")
          end
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~r/'last_modified' must be an ISO 8601 date and time/
      )
    end

    test "raises for 'yesterday'" do
      module("LastModified") do
        resource("doc.md") do
          annotations do
            last_modified("yesterday")
          end
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~r/'last_modified' must be an ISO 8601 date and time/
      )
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when last_modified is used at root level (only resource/2 is imported)" do
      module("LastModified") do
        last_modified("2025-01-01T00:00:00Z")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Resource.LastModified",
        "undefined function last_modified/1"
      )
    end

    test "raises when last_modified is used directly inside resource block" do
      module("LastModified") do
        resource("doc.md") do
          last_modified("2025-01-01T00:00:00Z")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'last_modified' here")
    end

    test "raises when last_modified is used inside icon block" do
      module("LastModified") do
        resource("doc.md") do
          icon do
            last_modified("2025-01-01T00:00:00Z")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'last_modified' here")
    end
  end
end
