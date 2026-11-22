#
# The gate checks of the method table.
#
# Every expected value comes from the behavior that the tests of
# `OzMcp.Validate.JsonRpc` already check: a gate that refuses gives the
# same answer as the validation gave before the table.
#
defmodule OzMcp.Method.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias OzMcp.Method.Capabilities

  # A config of a server that declares nothing.
  #
  @empty %{tools: nil, resources: nil, prompts: nil, capabilities: %{}}

  test "an empty gate list is always allowed" do
    assert Capabilities.allowed?([], @empty)
    assert Capabilities.allowed?([], %{tools: nil, capabilities: nil})
  end

  test "the tools gate passes only when the server declares tools" do
    assert Capabilities.allowed?([:tools], %{@empty | tools: %{}})
    refute Capabilities.allowed?([:tools], %{@empty | tools: nil})
  end

  test "the prompts gate passes only when the server declares prompts" do
    assert Capabilities.allowed?([:prompts], %{@empty | prompts: %{}})
    refute Capabilities.allowed?([:prompts], %{@empty | prompts: nil})
  end

  test "the resources gate passes only when the server declares resources" do
    assert Capabilities.allowed?([:resources], %{@empty | resources: %{}})
    refute Capabilities.allowed?([:resources], %{@empty | resources: nil})
  end

  describe "the resources_subscribe gate" do
    test "passes when the capabilities declare subscribe" do
      config = %{@empty | capabilities: %{resources: %{subscribe: true}}}
      assert Capabilities.allowed?([:resources_subscribe], config)
    end

    test "refuses when the capabilities declare subscribe as false" do
      config = %{@empty | capabilities: %{resources: %{subscribe: false}}}
      refute Capabilities.allowed?([:resources_subscribe], config)
    end

    test "refuses when the resources capability holds no subscribe member" do
      config = %{@empty | capabilities: %{resources: %{}}}
      refute Capabilities.allowed?([:resources_subscribe], config)
    end

    test "refuses when the resources capability is nil" do
      config = %{@empty | capabilities: %{resources: nil}}
      refute Capabilities.allowed?([:resources_subscribe], config)
    end

    test "refuses when the capabilities are nil" do
      config = %{@empty | capabilities: nil}
      refute Capabilities.allowed?([:resources_subscribe], config)
    end
  end

  describe "the logging gate" do
    test "passes when the capabilities declare logging" do
      config = %{@empty | capabilities: %{logging: %{}}}
      assert Capabilities.allowed?([:logging], config)
    end

    test "refuses when the logging capability is nil" do
      config = %{@empty | capabilities: %{logging: nil}}
      refute Capabilities.allowed?([:logging], config)
    end

    test "refuses when the capabilities are nil" do
      config = %{@empty | capabilities: nil}
      refute Capabilities.allowed?([:logging], config)
    end
  end

  describe "the completions gate" do
    test "passes when the atom key holds a capability" do
      config = %{@empty | capabilities: %{completions: %{}}}
      assert Capabilities.allowed?([:completions], config)
    end

    test "passes when the string key holds a capability" do
      config = %{@empty | capabilities: %{"completions" => %{}}}
      assert Capabilities.allowed?([:completions], config)
    end

    test "refuses when the capability is nil" do
      config = %{@empty | capabilities: %{completions: nil}}
      refute Capabilities.allowed?([:completions], config)
    end

    test "refuses when the capabilities are nil" do
      config = %{@empty | capabilities: nil}
      refute Capabilities.allowed?([:completions], config)
    end
  end

  describe "the tasks gate" do
    test "passes when the atom key holds a capability" do
      config = %{@empty | capabilities: %{tasks: %{}}}
      assert Capabilities.allowed?([:tasks], config)
    end

    test "passes when the string key holds a capability" do
      config = %{@empty | capabilities: %{"tasks" => %{}}}
      assert Capabilities.allowed?([:tasks], config)
    end

    test "refuses when the capability is nil" do
      config = %{@empty | capabilities: %{tasks: nil}}
      refute Capabilities.allowed?([:tasks], config)
    end

    test "refuses when the capabilities are nil" do
      config = %{@empty | capabilities: nil}
      refute Capabilities.allowed?([:tasks], config)
    end
  end

  describe "the tasks_list gate" do
    test "passes when the tasks capability holds the list member" do
      config = %{@empty | capabilities: %{tasks: %{list: %{}}}}
      assert Capabilities.allowed?([:tasks_list], config)
    end

    test "passes with string-keyed capability members" do
      config = %{@empty | capabilities: %{"tasks" => %{"list" => %{}}}}
      assert Capabilities.allowed?([:tasks_list], config)
    end

    test "refuses when the tasks capability holds no list member" do
      config = %{@empty | capabilities: %{tasks: %{}}}
      refute Capabilities.allowed?([:tasks_list], config)
    end

    test "refuses when the tasks capability is nil" do
      config = %{@empty | capabilities: %{tasks: nil}}
      refute Capabilities.allowed?([:tasks_list], config)
    end

    test "refuses when the capabilities are nil" do
      config = %{@empty | capabilities: nil}
      refute Capabilities.allowed?([:tasks_list], config)
    end
  end

  describe "the tasks_cancel gate" do
    test "passes when the tasks capability holds the cancel member" do
      config = %{@empty | capabilities: %{tasks: %{cancel: %{}}}}
      assert Capabilities.allowed?([:tasks_cancel], config)
    end

    test "passes with string-keyed capability members" do
      config = %{@empty | capabilities: %{"tasks" => %{"cancel" => %{}}}}
      assert Capabilities.allowed?([:tasks_cancel], config)
    end

    test "refuses when the tasks capability holds no cancel member" do
      config = %{@empty | capabilities: %{tasks: %{}}}
      refute Capabilities.allowed?([:tasks_cancel], config)
    end

    test "refuses when the capabilities are nil" do
      config = %{@empty | capabilities: nil}
      refute Capabilities.allowed?([:tasks_cancel], config)
    end
  end

  describe "a list of gates" do
    test "passes when every gate passes" do
      config = %{
        @empty
        | resources: %{},
          capabilities: %{resources: %{subscribe: true}}
      }

      assert Capabilities.allowed?([:resources, :resources_subscribe], config)
    end

    test "refuses when one gate refuses" do
      config = %{
        @empty
        | resources: %{},
          capabilities: %{resources: %{subscribe: false}}
      }

      refute Capabilities.allowed?([:resources, :resources_subscribe], config)
    end

    test "refuses when the resources gate refuses before the subscribe gate" do
      config = %{@empty | resources: nil, capabilities: %{resources: %{subscribe: true}}}
      refute Capabilities.allowed?([:resources, :resources_subscribe], config)
    end
  end
end
