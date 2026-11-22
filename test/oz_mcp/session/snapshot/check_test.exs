#
# The check of the map that a snapshot module gives back from `load/2`:
# a map of the wrong shape is refused with a reason.
#
defmodule OzMcp.Session.Snapshot.CheckTest do
  use ExUnit.Case, async: true

  alias OzMcp.Session.Snapshot.Check

  @valid %{
    principal_key: {nil, "user-1"},
    protocol_version: "2025-11-25",
    client_info: %{"name" => "check-test", "version" => "1"},
    client_capabilities: %{"roots" => %{"listChanged" => true}},
    log_level: :warning,
    subscriptions: ["file:///b.md", "file:///a.md"]
  }

  defp refuted_for(snapshot, reason) do
    assert Check.run(snapshot) == {:error, reason}
  end

  test "keeps a snapshot of the right shape" do
    assert {:ok, checked} = Check.run(@valid)
    assert checked.principal_key == {nil, "user-1"}
    assert checked.protocol_version == "2025-11-25"
    assert checked.client_info == %{"name" => "check-test", "version" => "1"}
    assert checked.client_capabilities == %{"roots" => %{"listChanged" => true}}
    assert checked.log_level == :warning
    assert checked.subscriptions == ["file:///a.md", "file:///b.md"]
  end

  test "keeps a snapshot without the optional values" do
    snapshot = %{
      principal_key: nil,
      protocol_version: nil,
      client_info: nil,
      client_capabilities: %{},
      log_level: nil,
      subscriptions: []
    }

    assert Check.run(snapshot) == {:ok, snapshot}
  end

  test "refuses a value that is not a map" do
    for value <- [nil, "text", 42, :an_atom, ["a", "list"]] do
      refuted_for(value, :not_a_map)
    end
  end

  test "refuses a struct" do
    refuted_for(DateTime.utc_now(), :not_a_map)
  end

  test "refuses a snapshot with a missing key" do
    refuted_for(Map.delete(@valid, :client_info), :missing_key)
    refuted_for(Map.delete(@valid, :client_capabilities), :missing_key)
    refuted_for(Map.delete(@valid, :subscriptions), :missing_key)
  end

  test "refuses a snapshot with string keys" do
    #
    # The form of a store that did not convert its JSON.
    #
    json = %{
      "principal_key" => nil,
      "protocol_version" => "2025-11-25",
      "client_info" => nil,
      "client_capabilities" => %{},
      "log_level" => nil,
      "subscriptions" => []
    }

    refuted_for(json, :missing_key)
  end

  test "removes an extra key" do
    assert {:ok, checked} = Check.run(Map.put(@valid, :extra, true))
    assert {:ok, same} = Check.run(@valid)
    assert checked == same
    assert map_size(checked) == 6
    refute Map.has_key?(checked, :extra)
  end

  test "refuses a principal key of the wrong shape" do
    for bad <- [
          "",
          "user-1",
          {nil, ""},
          {"issuer", ""},
          {"issuer", 42},
          {42, "user-1"},
          {nil, "user-1", "extra"},
          {nil},
          [:user, "user-1"]
        ] do
      refuted_for(%{@valid | principal_key: bad}, :principal_key)
    end
  end

  test "keeps a principal key with an issuer and without" do
    for key <- [{nil, "user-1"}, {"https://issuer.example", "user-1"}] do
      assert {:ok, checked} = Check.run(%{@valid | principal_key: key})
      assert checked.principal_key == key
    end
  end

  test "refuses a protocol version that the instance does not support" do
    for bad <- ["2024-11-05", "1.0", 2025] do
      refuted_for(%{@valid | protocol_version: bad}, :protocol_version)
    end
  end

  test "keeps a supported protocol version" do
    version = OzMcp.Protocol.latest()
    assert {:ok, checked} = Check.run(%{@valid | protocol_version: version})
    assert checked.protocol_version == version
  end

  test "refuses a client info that is not a map" do
    for bad <- ["text", 42, [:a, :list]] do
      refuted_for(%{@valid | client_info: bad}, :client_info)
    end
  end

  test "refuses client capabilities that are not a map" do
    for bad <- [nil, "text", 42, [:a, :list]] do
      refuted_for(%{@valid | client_capabilities: bad}, :client_capabilities)
    end
  end

  test "refuses a log level that is not a level" do
    for bad <- ["warning", :bogus, 42, true] do
      refuted_for(%{@valid | log_level: bad}, :log_level)
    end
  end

  test "keeps a level of OzMcp.LogLevel" do
    for level <- OzMcp.LogLevel.levels() do
      assert {:ok, checked} = Check.run(%{@valid | log_level: level})
      assert checked.log_level == level
    end
  end

  test "refuses subscriptions that are not a list of strings" do
    for bad <- [
          "file:///a.md",
          42,
          ["file:///a.md", 42],
          [nil],
          ["file:///a.md" | "file:///b.md"]
        ] do
      refuted_for(%{@valid | subscriptions: bad}, :subscriptions)
    end
  end

  test "gives the subscriptions back unique and sorted" do
    snapshot = %{@valid | subscriptions: ["file:///c.md", "file:///a.md", "file:///c.md"]}

    assert {:ok, checked} = Check.run(snapshot)
    assert checked.subscriptions == ["file:///a.md", "file:///c.md"]
  end

  test "keeps the scopes of the subscriptions and sorts their lists" do
    snapshot =
      Map.put(@valid, :subscription_scopes, %{
        "file:///secret.md" => ["files:write", "files:read"]
      })

    assert {:ok, checked} = Check.run(snapshot)

    assert checked.subscription_scopes == %{"file:///secret.md" => ["files:read", "files:write"]}
  end

  test "keeps a snapshot without the key of the scopes" do
    assert {:ok, checked} = Check.run(@valid)
    refute Map.has_key?(checked, :subscription_scopes)
  end

  test "removes a nil value of the key of the scopes" do
    #
    # The value of a store with a nullable column. The session would
    # crash at its first touch with a list of scopes, so the key goes.
    #
    snapshot = Map.put(@valid, :subscription_scopes, nil)

    assert {:ok, checked} = Check.run(snapshot)
    assert {:ok, same} = Check.run(@valid)
    assert checked == same
  end

  test "gives the lists of the scopes back unique and sorted" do
    snapshot =
      Map.put(@valid, :subscription_scopes, %{
        "file:///secret.md" => ["files:write", "files:read", "files:read"]
      })

    assert {:ok, checked} = Check.run(snapshot)

    assert checked.subscription_scopes == %{"file:///secret.md" => ["files:read", "files:write"]}
  end

  test "refuses subscription scopes of the wrong shape" do
    bad_maps = [
      "text",
      42,
      %{"file:///secret.md" => "files:write"},
      %{"file:///secret.md" => ["files:write", 42]},
      %{42 => ["files:write"]},
      %{"file:///secret.md" => ["files:write" | "files:read"]}
    ]

    for bad <- bad_maps do
      refuted_for(Map.put(@valid, :subscription_scopes, bad), :subscription_scopes)
    end
  end
end
