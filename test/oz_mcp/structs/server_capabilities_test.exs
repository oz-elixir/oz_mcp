defmodule OzMcp.Structs.ServerCapabilitiesTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.ServerCapabilities

  describe "struct defaults" do
    test "has nil defaults for all fields" do
      sc = %ServerCapabilities{}

      assert sc.experimental == nil
      assert sc.logging == nil
      assert sc.completions == nil
      assert sc.prompts == nil
      assert sc.resources == nil
      assert sc.tools == nil
      assert sc.tasks == nil
    end
  end

  describe "experimental/2" do
    test "sets experimental field" do
      sc = ServerCapabilities.experimental(%ServerCapabilities{}, %{"feature" => %{}})

      assert sc.experimental == %{"feature" => %{}}
    end
  end

  describe "logging/2" do
    test "sets logging field" do
      sc = ServerCapabilities.logging(%ServerCapabilities{}, %{})

      assert sc.logging == %{}
    end
  end

  describe "completions/2" do
    test "sets completions field" do
      sc = ServerCapabilities.completions(%ServerCapabilities{}, %{})

      assert sc.completions == %{}
    end
  end

  describe "resources/2" do
    test "sets resources field with subscribe" do
      sc = ServerCapabilities.resources(%ServerCapabilities{}, true)

      assert sc.resources == %{subscribe: true}
    end

    test "returns the struct unchanged when subscribe is false" do
      original = %ServerCapabilities{experimental: %{preserved: true}}
      sc = ServerCapabilities.resources(original, false)

      assert sc == original
      assert sc.resources == nil
    end

    test "returns the struct unchanged when subscribe is nil" do
      original = %ServerCapabilities{experimental: %{preserved: true}}
      sc = ServerCapabilities.resources(original, nil)

      assert sc == original
      assert sc.resources == nil
    end
  end

  describe "tasks/4" do
    test "sets tasks field with all objects" do
      sc =
        ServerCapabilities.tasks(
          %ServerCapabilities{},
          %{a: 1},
          %{b: 2},
          %{tools: %{call: %{}}}
        )

      assert sc.tasks == %{list: %{a: 1}, cancel: %{b: 2}, requests: %{tools: %{call: %{}}}}
    end

    test "sets tasks field with partial objects, skipping nil values" do
      sc = ServerCapabilities.tasks(%ServerCapabilities{}, %{a: 1}, nil, nil)

      assert sc.tasks == %{list: %{a: 1}}
    end

    test "accepts empty maps as capability objects" do
      sc = ServerCapabilities.tasks(%ServerCapabilities{}, %{}, %{}, %{})

      assert sc.tasks == %{list: %{}, cancel: %{}, requests: %{}}
    end

    test "raises when a value is a boolean" do
      assert_raise ArgumentError, "tasks capability values must be maps, got: true", fn ->
        ServerCapabilities.tasks(%ServerCapabilities{}, true, nil, nil)
      end
    end

    test "raises when a value is not a map" do
      assert_raise ArgumentError, "tasks capability values must be maps, got: \"bad\"", fn ->
        ServerCapabilities.tasks(%ServerCapabilities{}, nil, "bad", nil)
      end
    end

    test "returns the struct unchanged when all values are nil" do
      original = %ServerCapabilities{experimental: %{preserved: true}}
      sc = ServerCapabilities.tasks(original, nil, nil, nil)

      assert sc == original
      assert sc.tasks == nil
    end
  end

  describe "build/1" do
    test "returns empty map when all fields are nil" do
      result = ServerCapabilities.build(%ServerCapabilities{})

      assert result == %{}
    end

    test "includes experimental when set" do
      sc = %ServerCapabilities{experimental: %{"feature" => %{}}}
      result = ServerCapabilities.build(sc)

      assert result == %{experimental: %{"feature" => %{}}}
    end

    test "includes logging when set" do
      sc = %ServerCapabilities{logging: %{}}
      result = ServerCapabilities.build(sc)

      assert result == %{logging: %{}}
    end

    test "includes completions when set" do
      sc = %ServerCapabilities{completions: %{}}
      result = ServerCapabilities.build(sc)

      assert result == %{completions: %{}}
    end

    test "includes prompts when set" do
      sc = %ServerCapabilities{prompts: %{listChanged: true}}
      result = ServerCapabilities.build(sc)

      assert result == %{prompts: %{listChanged: true}}
    end

    test "includes resources when set" do
      sc = %ServerCapabilities{resources: %{subscribe: true, listChanged: true}}
      result = ServerCapabilities.build(sc)

      assert result == %{resources: %{subscribe: true, listChanged: true}}
    end

    test "includes tools when set" do
      sc = %ServerCapabilities{tools: %{listChanged: true}}
      result = ServerCapabilities.build(sc)

      assert result == %{tools: %{listChanged: true}}
    end

    test "includes tasks when set" do
      sc = %ServerCapabilities{tasks: %{list: %{}, cancel: %{}}}
      result = ServerCapabilities.build(sc)

      assert result == %{tasks: %{list: %{}, cancel: %{}}}
    end

    test "includes all fields when all are set" do
      sc = %ServerCapabilities{
        experimental: %{"feature" => %{}},
        logging: %{},
        completions: %{},
        prompts: %{listChanged: true},
        resources: %{subscribe: false, listChanged: true},
        tools: %{listChanged: false},
        tasks: %{list: %{}, cancel: %{}}
      }

      result = ServerCapabilities.build(sc)

      assert result == %{
               experimental: %{"feature" => %{}},
               logging: %{},
               completions: %{},
               prompts: %{listChanged: true},
               resources: %{subscribe: false, listChanged: true},
               tools: %{listChanged: false},
               tasks: %{list: %{}, cancel: %{}}
             }
    end

    test "includes only non-nil fields" do
      sc = %ServerCapabilities{
        logging: %{},
        tools: %{listChanged: true}
      }

      result = ServerCapabilities.build(sc)

      assert result == %{logging: %{}, tools: %{listChanged: true}}
      refute Map.has_key?(result, :experimental)
      refute Map.has_key?(result, :completions)
      refute Map.has_key?(result, :prompts)
      refute Map.has_key?(result, :resources)
      refute Map.has_key?(result, :tasks)
    end
  end
end
