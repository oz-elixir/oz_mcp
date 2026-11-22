defmodule OzMcp.Structs.IconTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.Icon

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      icon = %Icon{}

      assert icon.src == ""
      assert icon.mimeType == nil
      assert icon.sizes == nil
      assert icon.theme == nil
    end
  end

  describe "src/2" do
    test "sets src field" do
      icon = Icon.src(%Icon{}, "https://example.com/icon.png")

      assert icon.src == "https://example.com/icon.png"
    end
  end

  describe "mime_type/2" do
    test "sets mimeType field" do
      icon = Icon.mime_type(%Icon{}, "image/png")

      assert icon.mimeType == "image/png"
    end
  end

  describe "sizes/2" do
    test "sets sizes field" do
      icon = Icon.sizes(%Icon{}, ["16x16", "32x32"])

      assert icon.sizes == ["16x16", "32x32"]
    end
  end

  describe "theme/2" do
    test "sets theme to :light" do
      icon = Icon.theme(%Icon{}, :light)

      assert icon.theme == :light
    end

    test "sets theme to :dark" do
      icon = Icon.theme(%Icon{}, :dark)

      assert icon.theme == :dark
    end
  end

  describe "build/1" do
    test "builds with src only" do
      icon = %Icon{src: "https://example.com/icon.png"}
      result = Icon.build(icon)

      assert result == %{src: "https://example.com/icon.png"}
    end

    test "builds with http: for localhost" do
      icon = %Icon{src: "http://localhost:4000/a.png"}
      result = Icon.build(icon)

      assert result == %{src: "http://localhost:4000/a.png"}
    end

    test "builds with http: for ::1" do
      icon = %Icon{src: "http://[::1]:4000/a.png"}
      result = Icon.build(icon)

      assert result == %{src: "http://[::1]:4000/a.png"}
    end

    test "raises for http: with a public host" do
      icon = %Icon{src: "http://example.com/a.png"}

      assert_raise ArgumentError,
                   "The 'src' field must be an https: URL, an http: URL of a loopback host, " <>
                     ~s|or a data: URI, got: "http://example.com/a.png"|,
                   fn ->
                     Icon.build(icon)
                   end
    end

    test "raises for javascript:" do
      icon = %Icon{src: "javascript:alert(1)"}

      assert_raise ArgumentError,
                   "The 'src' field must be an https: URL, an http: URL of a loopback host, " <>
                     ~s|or a data: URI, got: "javascript:alert(1)"|,
                   fn ->
                     Icon.build(icon)
                   end
    end

    test "raises for a relative path" do
      icon = %Icon{src: "/icons/a.png"}

      assert_raise ArgumentError,
                   "The 'src' field must be an https: URL, an http: URL of a loopback host, " <>
                     ~s|or a data: URI, got: "/icons/a.png"|,
                   fn ->
                     Icon.build(icon)
                   end
    end

    test "raises when sizes has a bad entry" do
      icon = %Icon{src: "https://example.com/icon.png", sizes: ["48"]}

      assert_raise ArgumentError,
                   ~s|The 'sizes' field must be "any" or a "WxH" string such as "48x48", got: "48"|,
                   fn ->
                     Icon.build(icon)
                   end
    end

    test "raises when sizes has a non-string entry" do
      icon = %Icon{src: "https://example.com/icon.png", sizes: [48]}

      assert_raise ArgumentError,
                   ~s|The 'sizes' field must be "any" or a "WxH" string such as "48x48", got: 48|,
                   fn ->
                     Icon.build(icon)
                   end
    end

    test "builds with sizes ['48x48', 'any']" do
      icon = %Icon{src: "https://example.com/icon.png", sizes: ["48x48", "any"]}
      result = Icon.build(icon)

      assert result == %{src: "https://example.com/icon.png", sizes: ["48x48", "any"]}
    end

    test "raises when src is empty" do
      icon = %Icon{src: ""}

      assert_raise ArgumentError, "The 'src' field cannot be an empty string", fn ->
        Icon.build(icon)
      end
    end

    test "raises when src is not a string" do
      icon = struct(Icon, %{src: 123})

      assert_raise ArgumentError, "The 'src' field is required and must be a string", fn ->
        Icon.build(icon)
      end
    end

    test "raises when theme is not :light or :dark" do
      icon = struct(Icon, src: "https://example.com/icon.png", theme: :blue)

      assert_raise ArgumentError,
                   "'theme' must be :light, :dark, \"light\", or \"dark\", got: :blue",
                   fn ->
                     Icon.build(icon)
                   end
    end

    test "includes mimeType when set" do
      icon = %Icon{src: "https://example.com/icon.png", mimeType: "image/png"}
      result = Icon.build(icon)

      assert result == %{mimeType: "image/png", src: "https://example.com/icon.png"}
    end

    test "includes sizes when set" do
      icon = %Icon{src: "https://example.com/icon.png", sizes: ["16x16", "32x32"]}
      result = Icon.build(icon)

      assert result == %{src: "https://example.com/icon.png", sizes: ["16x16", "32x32"]}
    end

    test "includes theme when set" do
      icon = %Icon{src: "https://example.com/icon.png", theme: :dark}
      result = Icon.build(icon)

      assert result == %{src: "https://example.com/icon.png", theme: :dark}
    end

    test "includes all fields when all are set" do
      icon = %Icon{
        src: "https://example.com/icon.png",
        mimeType: "image/svg+xml",
        sizes: ["16x16", "32x32", "64x64"],
        theme: :light
      }

      result = Icon.build(icon)

      assert result == %{
               mimeType: "image/svg+xml",
               src: "https://example.com/icon.png",
               sizes: ["16x16", "32x32", "64x64"],
               theme: :light
             }
    end

    test "does not include nil optional fields" do
      icon = %Icon{
        src: "https://example.com/icon.png",
        mimeType: "image/png",
        sizes: nil,
        theme: nil
      }

      result = Icon.build(icon)

      assert result == %{mimeType: "image/png", src: "https://example.com/icon.png"}
      refute Map.has_key?(result, :sizes)
      refute Map.has_key?(result, :theme)
    end

    test "builds with data URI src" do
      icon = %Icon{src: "data:image/png;base64,iVBORw0KGgo="}
      result = Icon.build(icon)

      assert result == %{src: "data:image/png;base64,iVBORw0KGgo="}
    end
  end
end
