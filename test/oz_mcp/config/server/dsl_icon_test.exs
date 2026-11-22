#
# Tests for the `icon/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLIconTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  alias OzMcp.Structs.Icon

  describe "icon/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts an icon block with src" do
      config =
        module("Icon") do
          server_info do
            icon(src: "https://a.com/icon.png")
          end
        end
        |> compile_config()

      assert config.server_info.icons == [
               %Icon{src: "https://a.com/icon.png", mimeType: nil, sizes: nil, theme: nil}
             ]
    end

    test "accepts an icon block with all fields" do
      config =
        module("Icon") do
          server_info do
            icon do
              src "https://a.com/icon.png"
              mime_type "image/png"
              sizes ["16x16", "32x32"]
              theme "dark"
            end
          end
        end
        |> compile_config()

      assert config.server_info.icons == [
               %Icon{
                 src: "https://a.com/icon.png",
                 mimeType: "image/png",
                 sizes: ["16x16", "32x32"],
                 theme: "dark"
               }
             ]
    end

    test "accepts multiple icon blocks" do
      config =
        module("Icon") do
          server_info do
            icon(src: "https://a.com/icon.png", mime_type: "image/png")

            icon do
              src "https://b.com/hero.png"
              mime_type "image/jpeg"
              sizes ["1200x800"]
              theme "dark"
            end
          end
        end
        |> compile_config()

      assert config.server_info.icons == [
               %Icon{
                 src: "https://a.com/icon.png",
                 mimeType: "image/png",
                 sizes: nil,
                 theme: nil
               },
               %Icon{
                 src: "https://b.com/hero.png",
                 mimeType: "image/jpeg",
                 sizes: ["1200x800"],
                 theme: "dark"
               }
             ]
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when icon block has no src" do
      module("Icon") do
        server_info do
          icon(src: :_none_, mime_type: "image/png")
        end
      end
      |> assert_compile_raise(RuntimeError, "icon 'src' is required")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises icon cannot be at root level" do
      module("Icon") do
        icon(src: "https://a.com/icon.png")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Icon",
        "undefined function icon/1"
      )
    end

    test "raises when icon is used inside tools block" do
      module("Icon") do
        tools do
          icon(src: "https://a.com/icon.png")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'icon' here")
    end

    test "raises when icon is used inside icon block" do
      module("Icon") do
        server_info do
          icon do
            src "https://a.com/icon.png"
            icon(src: "https://b.com/icon.png")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'icon' here")
    end
  end
end
