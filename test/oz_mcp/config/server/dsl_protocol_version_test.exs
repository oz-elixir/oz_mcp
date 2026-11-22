#
# Tests for the `protocol_version/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLProtocolVersionTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "protocol_version/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a supported non-empty string" do
      config =
        module("ProtocolVersion") do
          protocol_version "2025-11-25"
        end
        |> compile_config()

      assert config.protocol_version == "2025-11-25"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when protocol_version is not a string" do
      module("ProtocolVersion") do
        protocol_version 123
      end
      |> assert_compile_raise(ArgumentError, "'protocol_version' must be a string, got: 123")
    end

    test "raises when protocol_version is an empty string" do
      module("ProtocolVersion") do
        protocol_version ""
      end
      |> assert_compile_raise(ArgumentError, "'protocol_version' cannot be an empty string")
    end

    test "raises when protocol_version is not a supported version" do
      module("ProtocolVersion") do
        protocol_version "2024-11-05"
      end
      |> assert_compile_raise(
        ArgumentError,
        ~s('protocol_version' must be one of ["2025-11-25"], got: "2024-11-05")
      )
    end

    test "raises when protocol_version is used multiple times" do
      module("ProtocolVersion") do
        protocol_version "2025-11-25"
        protocol_version "2025-11-25"
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'protocol_version' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when protocol_version is used inside tools block" do
      module("ProtocolVersion") do
        tools do
          protocol_version "2025-11-25"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'protocol_version' here")
    end
  end
end
