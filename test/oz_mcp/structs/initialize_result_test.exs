defmodule OzMcp.Structs.InitializeResultTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.{Implementation, InitializeResult, ServerCapabilities}
  alias Support.Helpers.Utils

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      ir = %InitializeResult{}

      assert ir._meta == nil
      assert ir.protocolVersion == ""
      assert ir.capabilities == %ServerCapabilities{}
      assert ir.serverInfo == %Implementation{}
      assert ir.instructions == nil
      assert ir.extras == nil
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      ir = InitializeResult._meta(%InitializeResult{}, %{"foo" => "bar"})

      assert ir._meta == %{"foo" => "bar"}
    end
  end

  describe "protocol_version/2" do
    test "sets protocolVersion field" do
      ir = InitializeResult.protocol_version(%InitializeResult{}, "2025-11-25")

      assert ir.protocolVersion == "2025-11-25"
    end
  end

  describe "capabilities/2" do
    test "sets capabilities field" do
      caps = %ServerCapabilities{logging: %{}, tools: %{listChanged: true}}
      ir = InitializeResult.capabilities(%InitializeResult{}, caps)

      assert ir.capabilities == caps
    end
  end

  describe "server_info/2" do
    test "sets serverInfo field" do
      info = %Implementation{name: "my-server", version: "1.0.0"}
      ir = InitializeResult.server_info(%InitializeResult{}, info)

      assert ir.serverInfo == info
    end
  end

  describe "instructions/2" do
    test "sets instructions field" do
      ir = InitializeResult.instructions(%InitializeResult{}, "Run with care.")

      assert ir.instructions == "Run with care."
    end
  end

  describe "extras/2" do
    test "sets extras field" do
      ir = InitializeResult.extras(%InitializeResult{}, %{"customKey" => "value"})

      assert ir.extras == %{"customKey" => "value"}
    end
  end

  describe "build/1" do
    test "builds with required fields only" do
      caps = %ServerCapabilities{logging: %{}}
      info = %Implementation{name: "my-server", version: "1.0.0"}

      ir = %InitializeResult{
        protocolVersion: "2025-11-25",
        capabilities: caps,
        serverInfo: info
      }

      result = InitializeResult.build(ir)

      assert result == %{
               protocolVersion: "2025-11-25",
               capabilities: %{logging: %{}},
               serverInfo: %{name: "my-server", version: "1.0.0"}
             }
    end

    test "raises when protocolVersion is empty" do
      ir = %InitializeResult{
        protocolVersion: "",
        capabilities: %ServerCapabilities{},
        serverInfo: %Implementation{name: "my-server", version: "1.0.0"}
      }

      assert_raise ArgumentError, "The 'protocolVersion' field cannot be an empty string", fn ->
        InitializeResult.build(ir)
      end
    end

    test "raises when capabilities is nil" do
      ir =
        struct(InitializeResult, %{
          protocolVersion: "2025-11-25",
          capabilities: nil,
          serverInfo: %Implementation{name: "my-server", version: "1.0.0"}
        })

      assert_raise ArgumentError,
                   "The 'capabilities' field is required and must be a OzMcp.Structs.ServerCapabilities struct",
                   fn ->
                     InitializeResult.build(ir)
                   end
    end

    test "raises when capabilities is the wrong struct" do
      ir =
        struct(InitializeResult, %{
          protocolVersion: "2025-11-25",
          capabilities: %Implementation{},
          serverInfo: %Implementation{name: "my-server", version: "1.0.0"}
        })

      assert_raise ArgumentError,
                   "The 'capabilities' field is required and must be a OzMcp.Structs.ServerCapabilities struct",
                   fn ->
                     InitializeResult.build(ir)
                   end
    end

    test "raises when serverInfo is nil" do
      ir =
        struct(InitializeResult, %{
          protocolVersion: "2025-11-25",
          capabilities: %ServerCapabilities{},
          serverInfo: nil
        })

      assert_raise ArgumentError,
                   "The 'serverInfo' field is required and must be a OzMcp.Structs.Implementation struct",
                   fn ->
                     InitializeResult.build(ir)
                   end
    end

    test "raises when serverInfo is the wrong struct" do
      ir =
        struct(InitializeResult, %{
          protocolVersion: "2025-11-25",
          capabilities: %ServerCapabilities{},
          serverInfo: %ServerCapabilities{}
        })

      assert_raise ArgumentError,
                   "The 'serverInfo' field is required and must be a OzMcp.Structs.Implementation struct",
                   fn ->
                     InitializeResult.build(ir)
                   end
    end

    test "raises when protocolVersion is not a string" do
      ir =
        struct(InitializeResult, %{
          protocolVersion: 2025,
          capabilities: %ServerCapabilities{},
          serverInfo: %Implementation{name: "my-server", version: "1.0.0"}
        })

      assert_raise ArgumentError,
                   "The 'protocolVersion' field is required and must be a string",
                   fn ->
                     InitializeResult.build(ir)
                   end
    end

    test "builds capabilities with ServerCapabilities.build/1" do
      caps = %ServerCapabilities{
        logging: %{},
        tools: %{listChanged: true},
        resources: %{subscribe: false, listChanged: true}
      }

      info = %Implementation{name: "my-server", version: "1.0.0"}

      ir = %InitializeResult{
        protocolVersion: "2025-11-25",
        capabilities: caps,
        serverInfo: info
      }

      result = InitializeResult.build(ir)

      assert result.capabilities == %{
               logging: %{},
               tools: %{listChanged: true},
               resources: %{subscribe: false, listChanged: true}
             }
    end

    test "builds serverInfo with Implementation.build/1" do
      info = %Implementation{
        name: "my-server",
        version: "2.0.0",
        title: "My Server",
        description: "A test server"
      }

      ir = %InitializeResult{
        protocolVersion: "2025-11-25",
        capabilities: %ServerCapabilities{},
        serverInfo: info
      }

      result = InitializeResult.build(ir)

      assert result.serverInfo == %{
               name: "my-server",
               version: "2.0.0",
               title: "My Server",
               description: "A test server"
             }
    end

    test "includes _meta when set" do
      ir = %InitializeResult{
        protocolVersion: "2025-11-25",
        capabilities: %ServerCapabilities{},
        serverInfo: %Implementation{name: "s", version: "1.0.0"},
        _meta: %{"foo" => "bar"}
      }

      result = InitializeResult.build(ir)

      assert result._meta == %{"foo" => "bar"}
    end

    test "includes instructions when set" do
      ir = %InitializeResult{
        protocolVersion: "2025-11-25",
        capabilities: %ServerCapabilities{},
        serverInfo: %Implementation{name: "s", version: "1.0.0"},
        instructions: "Be careful."
      }

      result = InitializeResult.build(ir)

      assert result.instructions == "Be careful."
    end

    test "includes extras when set" do
      ir = %InitializeResult{
        protocolVersion: "2025-11-25",
        capabilities: %ServerCapabilities{},
        serverInfo: %Implementation{name: "s", version: "1.0.0"},
        extras: %{"customKey" => "value"}
      }

      result = InitializeResult.build(ir)

      assert result["customKey"] == "value"
    end

    test "does not include nil optional fields" do
      ir = %InitializeResult{
        protocolVersion: "2025-11-25",
        capabilities: %ServerCapabilities{},
        serverInfo: %Implementation{name: "s", version: "1.0.0"},
        _meta: nil,
        instructions: nil,
        extras: nil
      }

      result = InitializeResult.build(ir)

      refute Map.has_key?(result, :_meta)
      refute Map.has_key?(result, :instructions)
    end

    test "includes all fields when all are set" do
      caps = %ServerCapabilities{logging: %{}, tools: %{listChanged: true}}

      info = %Implementation{name: "my-server", version: "3.0.0", title: "My Server"}

      ir = %InitializeResult{
        protocolVersion: "2025-11-25",
        capabilities: caps,
        serverInfo: info,
        instructions: "Have fun.",
        _meta: %{"foo" => "bar"},
        extras: %{"customKey" => 42}
      }

      result = InitializeResult.build(ir)

      assert result.protocolVersion == "2025-11-25"
      assert result.capabilities == %{logging: %{}, tools: %{listChanged: true}}
      assert result.serverInfo == %{name: "my-server", version: "3.0.0", title: "My Server"}
      assert result.instructions == "Have fun."
      assert result._meta == %{"foo" => "bar"}
      assert result["customKey"] == 42
    end

    test "extras keys do not overwrite existing fields" do
      ir = %InitializeResult{
        protocolVersion: "2025-11-25",
        capabilities: %ServerCapabilities{},
        serverInfo: %Implementation{name: "s", version: "1.0.0"},
        extras: %{protocolVersion: "should-not-overwrite"}
      }

      result = InitializeResult.build(ir)

      assert result.protocolVersion == "2025-11-25"
    end

    test "an extra never makes a second JSON key with the name of a field" do
      ir = %InitializeResult{
        protocolVersion: "2025-11-25",
        capabilities: %ServerCapabilities{},
        serverInfo: %Implementation{name: "s", version: "1.0.0"},
        extras: %{"protocolVersion" => "x"}
      }

      json = ir |> InitializeResult.build() |> Utils.encode_json()

      assert json =~ ~s("protocolVersion":"2025-11-25")
      refute json =~ ~s("protocolVersion":"x")
    end
  end
end
