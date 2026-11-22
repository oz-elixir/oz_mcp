defmodule OzMcp.Structs.ImplementationTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.{Icon, Implementation}

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      impl = %Implementation{}

      assert impl.icons == nil
      assert impl.name == ""
      assert impl.title == nil
      assert impl.version == ""
      assert impl.description == nil
      assert impl.websiteUrl == nil
    end
  end

  describe "icons/2" do
    test "sets icons field" do
      icon = %Icon{src: "https://example.com/icon.png"}
      impl = Implementation.icons(%Implementation{}, [icon])

      assert impl.icons == [icon]
    end
  end

  describe "name/2" do
    test "sets name field" do
      impl = Implementation.name(%Implementation{}, "my-server")

      assert impl.name == "my-server"
    end
  end

  describe "title/2" do
    test "sets title field" do
      impl = Implementation.title(%Implementation{}, "My Server")

      assert impl.title == "My Server"
    end
  end

  describe "version/2" do
    test "sets version field" do
      impl = Implementation.version(%Implementation{}, "1.0.0")

      assert impl.version == "1.0.0"
    end
  end

  describe "description/2" do
    test "sets description field" do
      impl = Implementation.description(%Implementation{}, "A test server")

      assert impl.description == "A test server"
    end
  end

  describe "website_url/2" do
    test "sets websiteUrl field" do
      impl = Implementation.website_url(%Implementation{}, "https://example.com")

      assert impl.websiteUrl == "https://example.com"
    end
  end

  describe "build/1" do
    test "builds with required fields only" do
      impl = %Implementation{name: "my-server", version: "1.0.0"}
      result = Implementation.build(impl)

      assert result == %{name: "my-server", version: "1.0.0"}
    end

    test "raises when name is empty" do
      impl = %Implementation{name: "", version: "1.0.0"}

      assert_raise ArgumentError, "The 'name' field cannot be an empty string", fn ->
        Implementation.build(impl)
      end
    end

    test "raises when name is not a string" do
      impl = struct(Implementation, %{name: 123, version: "1.0.0"})

      assert_raise ArgumentError, "The 'name' field is required and must be a string", fn ->
        Implementation.build(impl)
      end
    end

    test "raises when version is empty" do
      impl = %Implementation{name: "my-server", version: ""}

      assert_raise ArgumentError, "The 'version' field cannot be an empty string", fn ->
        Implementation.build(impl)
      end
    end

    test "raises when version is not a string" do
      impl = struct(Implementation, %{name: "my-server", version: 123})

      assert_raise ArgumentError, "The 'version' field is required and must be a string", fn ->
        Implementation.build(impl)
      end
    end

    test "includes title when set" do
      impl = %Implementation{name: "my-server", version: "1.0.0", title: "My Server"}
      result = Implementation.build(impl)

      assert result == %{name: "my-server", version: "1.0.0", title: "My Server"}
    end

    test "includes description when set" do
      impl = %Implementation{name: "my-server", version: "1.0.0", description: "A test server"}
      result = Implementation.build(impl)

      assert result == %{name: "my-server", version: "1.0.0", description: "A test server"}
    end

    test "includes websiteUrl when set" do
      impl = %Implementation{
        name: "my-server",
        version: "1.0.0",
        websiteUrl: "https://example.com"
      }

      result = Implementation.build(impl)

      assert result == %{name: "my-server", version: "1.0.0", websiteUrl: "https://example.com"}
    end

    test "includes icons when set" do
      icon = %Icon{src: "https://example.com/icon.png", mimeType: "image/png"}

      impl = %Implementation{
        name: "my-server",
        version: "1.0.0",
        icons: [icon]
      }

      result = Implementation.build(impl)

      assert result == %{
               name: "my-server",
               version: "1.0.0",
               icons: [%{src: "https://example.com/icon.png", mimeType: "image/png"}]
             }
    end

    test "includes all fields when all are set" do
      icon = %Icon{src: "https://example.com/icon.png"}

      impl = %Implementation{
        icons: [icon],
        name: "my-server",
        title: "My Server",
        version: "2.0.0",
        description: "My server",
        websiteUrl: "https://example.com"
      }

      result = Implementation.build(impl)

      assert result == %{
               icons: [%{src: "https://example.com/icon.png"}],
               name: "my-server",
               title: "My Server",
               version: "2.0.0",
               description: "My server",
               websiteUrl: "https://example.com"
             }
    end

    test "does not include nil optional fields" do
      impl = %Implementation{
        name: "my-server",
        version: "1.0.0",
        title: nil,
        description: nil,
        websiteUrl: nil,
        icons: nil
      }

      result = Implementation.build(impl)

      assert result == %{name: "my-server", version: "1.0.0"}
      refute Map.has_key?(result, :title)
      refute Map.has_key?(result, :description)
      refute Map.has_key?(result, :websiteUrl)
      refute Map.has_key?(result, :icons)
    end
  end
end
