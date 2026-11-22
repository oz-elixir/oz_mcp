#
# Tests for the `resource/2` macro of the resource DSL.
# See: lib/oz_mcp/config/resource/dsl.ex
#
defmodule OzMcp.Config.Resource.DSLResourceTest do
  use ExUnit.Case, async: true
  import Support.Factories.Resource

  describe "resource/2" do
    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when resource name is not a string" do
      module("Resource") do
        resource(123)
      end
      |> assert_compile_raise(ArgumentError, "name must be a string, got: 123")
    end

    test "raises when resource name is an empty string" do
      module("Resource") do
        resource("")
      end
      |> assert_compile_raise(ArgumentError, "'name' cannot be an empty string")
    end

    test "raises when uri is not present" do
      module("Resource") do
        resource("doc.md", uri: :_none_)
      end
      |> assert_compile_raise(RuntimeError, "resource 'uri' is required")
    end

    test "raises when two resources have the same uri" do
      module("Resource") do
        resource("first.md", uri: "file:///same.md")
        resource("second.md", uri: "file:///same.md")
      end
      |> assert_compile_raise(
        ArgumentError,
        "duplicate resource uri: \"file:///same.md\" is declared two times"
      )
    end

    test "accepts two resources with the same name and different uris" do
      mod =
        module("Resource") do
          resource("doc.md", uri: "file:///a.md", title: "First")
          resource("doc.md", uri: "file:///b.md", title: "Second")
        end
        |> compile()

      assert Enum.map(mod.list(), & &1.uri) == ["file:///a.md", "file:///b.md"]
    end

    # -----------------------------------------------------------------------
    # Warnings
    # -----------------------------------------------------------------------

    test "warn: true emits warning when title is missing in resource" do
      module("Resource", _warn_: true) do
        resource("doc.md", description: "A doc")
      end
      |> assert_compile_warning("The resource doc.md does not have a title configuration")
    end

    test "warn: true emits warning when description is missing in resource" do
      module("Resource", _warn_: true) do
        resource("doc.md", title: "Doc")
      end
      |> assert_compile_warning("The resource doc.md does not have a description configuration")
    end

    test "warn: true emits both warnings when title and description are missing in resource" do
      module("Resource", _warn_: true) do
        resource("doc.md")
      end
      |> assert_compile_warning("The resource doc.md does not have a title configuration")

      module("Resource", _warn_: true) do
        resource("doc.md")
      end
      |> assert_compile_warning("The resource doc.md does not have a description configuration")
    end

    test "warn: false suppresses resource warnings when title and description are missing" do
      module("Resource") do
        resource("doc.md")
      end
      |> refute_compile_warning([
        "does not have a title configuration",
        "does not have a description configuration"
      ])
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when resource block is nested inside another resource block" do
      module("Resource") do
        resource("outer.md") do
          resource("inner.md")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'resource' here")
    end

    test "raises when resource block is used inside icon block" do
      module("Resource") do
        resource("outer.md") do
          icon do
            resource("inner.md")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'resource' here")
    end

    test "raises when resource block is used inside annotations block" do
      module("Resource") do
        resource("outer.md") do
          annotations(audience: ["user"]) do
            resource("inner.md")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'resource' here")
    end
  end
end
