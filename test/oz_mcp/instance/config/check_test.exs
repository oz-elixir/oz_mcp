defmodule OzMcp.Instance.Config.CheckTest do
  use ExUnit.Case, async: true

  alias OzMcp.Instance.Config.Check
  alias OzMcp.Instance.Config.Schema
  alias Support.Servers

  @server Servers.Default

  describe "value/3 - the type :pos_int" do
    test "gives a positive integer back" do
      assert Check.value({:k, :pos_int, 1, []}, 5, @server) == 5
    end

    test "the message holds the unit, `nil` and `:infinity` in the order of the flags" do
      row = {:k, :pos_int, 1, [unit: "ms", null: true, infinity: true]}

      assert_raise ArgumentError,
                   "k must be a positive integer (ms) or nil or :infinity, got: 0",
                   fn -> Check.value(row, 0, @server) end
    end

    test "`nil` passes only with the flag `null`" do
      assert Check.value({:k, :pos_int, nil, [null: true]}, nil, @server) == nil

      assert_raise ArgumentError, "k must be a positive integer, got: nil", fn ->
        Check.value({:k, :pos_int, 1, []}, nil, @server)
      end
    end

    test "`:infinity` passes only with the flag `infinity`" do
      assert Check.value({:k, :pos_int, 1, [infinity: true]}, :infinity, @server) == :infinity

      assert_raise ArgumentError, "k must be a positive integer, got: :infinity", fn ->
        Check.value({:k, :pos_int, 1, []}, :infinity, @server)
      end
    end

    test "refuses zero, a negative integer, a float and a string" do
      row = {:k, :pos_int, 1, []}

      for value <- [0, -1, 1.5, "5"] do
        assert_raise ArgumentError, "k must be a positive integer, got: #{inspect(value)}", fn ->
          Check.value(row, value, @server)
        end
      end
    end

    test "respects the maximum TTL limit" do
      row = {:k, :pos_int, 1, [max: 1_000]}

      assert Check.value(row, 1000, @server) == 1000

      assert_raise ArgumentError, "k must be a positive integer at most 1000, got: 1001", fn ->
        Check.value(row, 1001, @server)
      end
    end

    test "the flag max refuses a value above it and names it in the message" do
      row = {:k, :pos_int, 1, [unit: "ms", null: true, max: 10]}

      assert Check.value(row, 10, @server) == 10
      assert Check.value(row, nil, @server) == nil

      assert_raise ArgumentError,
                   "k must be a positive integer (ms) at most 10 or nil, got: 11",
                   fn ->
                     Check.value(row, 11, @server)
                   end
    end
  end

  describe "value/3 - the type :non_neg_int" do
    test "gives zero and a positive integer back" do
      assert Check.value({:k, :non_neg_int, 0, []}, 0, @server) == 0
      assert Check.value({:k, :non_neg_int, 0, []}, 300_000, @server) == 300_000
    end

    test "refuses a negative integer and a value of another kind" do
      row = {:k, :non_neg_int, 0, []}

      for value <- [-1, 1.5, nil, "0"] do
        assert_raise ArgumentError,
                     "k must be a non-negative integer, got: #{inspect(value)}",
                     fn -> Check.value(row, value, @server) end
      end
    end
  end

  describe "value/3 - the type :boolean" do
    test "gives `true` and `false` back" do
      assert Check.value({:k, :boolean, true, []}, true, @server) == true
      assert Check.value({:k, :boolean, true, []}, false, @server) == false
    end

    test "refuses `nil` and a value of another kind" do
      row = {:k, :boolean, true, []}

      for value <- [nil, "true", 0] do
        assert_raise ArgumentError, "k must be a boolean, got: #{inspect(value)}", fn ->
          Check.value(row, value, @server)
        end
      end
    end
  end

  describe "value/3 - the type {:module, label, required}" do
    @store_contract [init: 1, put: 2, get: 2]
    @row {:task_store, {:module, "task store", @store_contract}, nil, []}

    test "gives a module that exports the functions of the contract back" do
      assert Check.value(@row, OzMcp.Tasks.EtsStore, @server) == OzMcp.Tasks.EtsStore
    end

    test "the message holds the server, the label and the missing functions" do
      assert_raise ArgumentError,
                   "server #{@server |> inspect()}: the task store #{inspect(@server)} " <>
                     "must export init/1, put/2, get/2",
                   fn -> Check.value(@row, @server, @server) end
    end

    test "a module that the runtime did not load misses every function" do
      assert_raise ArgumentError,
                   "server #{inspect(@server)}: the task store No.SuchStore " <>
                     "must export init/1, put/2, get/2",
                   fn -> Check.value(@row, No.SuchStore, @server) end
    end
  end

  describe "value/3 - the type :custom" do
    test "gives the value of `resource_url` back without a check" do
      for value <- [nil, "https://app.example.com", :anything] do
        assert Check.value({:resource_url, :custom, nil, []}, value, @server) == value
      end
    end
  end

  describe "custom/3 - allowed_origins" do
    test "`nil` becomes an empty list" do
      assert Check.custom(:allowed_origins, nil, @server) == []
    end

    test "gives a list of non-empty strings back" do
      origins = ["https://app.example.com"]

      assert Check.custom(:allowed_origins, origins, @server) == origins
    end

    test "refuses a value that is not a list" do
      assert_raise ArgumentError,
                   ~s{allowed_origins must be a list, got: "https://a.example"},
                   fn -> Check.custom(:allowed_origins, "https://a.example", @server) end
    end

    test "refuses the wildcard \"*\"" do
      assert_raise ArgumentError,
                   ~s{allowed_origins: "*" is not a wildcard. Give each origin, } <>
                     ~s{for example "https://app.example.com"},
                   fn -> Check.custom(:allowed_origins, ["*"], @server) end
    end

    test "refuses an element that is not a non-empty string" do
      for origin <- [:localhost, ""] do
        assert_raise ArgumentError,
                     "allowed_origins must hold non-empty strings, got: #{inspect(origin)}",
                     fn -> Check.custom(:allowed_origins, [origin], @server) end
      end
    end
  end

  describe "custom/3 - allowed_hosts" do
    test "`nil` becomes `:any`" do
      assert Check.custom(:allowed_hosts, nil, @server) == :any
      assert Check.custom(:allowed_hosts, :any, @server) == :any
    end

    test "lower-cases each host of a list" do
      assert Check.custom(:allowed_hosts, ["App.Example.COM"], @server) == ["app.example.com"]
    end

    test "refuses a value that is not `:any` or a list" do
      assert_raise ArgumentError,
                   "allowed_hosts must be :any or a list of host names, got: :nope",
                   fn -> Check.custom(:allowed_hosts, :nope, @server) end
    end

    test "refuses an element that is not a non-empty string" do
      for host <- [:localhost, ""] do
        assert_raise ArgumentError,
                     "allowed_hosts must hold non-empty strings, got: #{inspect(host)}",
                     fn -> Check.custom(:allowed_hosts, [host], @server) end
      end
    end
  end

  describe "custom/3 - telemetry_prefix" do
    test "gives a non-empty list of atoms back" do
      assert Check.custom(:telemetry_prefix, [:oz_mcp, :test], @server) == [:oz_mcp, :test]
    end

    test "refuses an empty list, a non-atom element and `nil`" do
      for prefix <- [[], [:oz_mcp, "test"], nil] do
        assert_raise ArgumentError,
                     "telemetry_prefix must be a non-empty list of atoms, got: #{inspect(prefix)}",
                     fn -> Check.custom(:telemetry_prefix, prefix, @server) end
      end
    end
  end

  describe "relation!/2" do
    test ":at_most refuses a value higher than the cap" do
      opts = %{task_default_ttl_ms: 5000, task_max_ttl_ms: 1000}

      assert_raise ArgumentError,
                   "task_default_ttl_ms (5000) must not be higher than task_max_ttl_ms (1000)",
                   fn ->
                     Check.relation!({:at_most, :task_default_ttl_ms, :task_max_ttl_ms}, opts)
                   end
    end

    test ":at_most accepts a value under the cap, the cap itself and `nil` values" do
      relation = {:at_most, :task_default_ttl_ms, :task_max_ttl_ms}

      assert Check.relation!(relation, %{task_default_ttl_ms: 1000, task_max_ttl_ms: 5000}) == :ok
      assert Check.relation!(relation, %{task_default_ttl_ms: 5000, task_max_ttl_ms: 5000}) == :ok
      assert Check.relation!(relation, %{task_default_ttl_ms: nil, task_max_ttl_ms: 5000}) == :ok
      assert Check.relation!(relation, %{task_default_ttl_ms: 5000, task_max_ttl_ms: nil}) == :ok
    end

    test ":at_least refuses a value lower than the floor" do
      opts = %{sse_event_log_session_bytes: 10, sse_event_log_bytes: 100}

      assert_raise ArgumentError,
                   "sse_event_log_session_bytes (10) must not be lower than " <>
                     "sse_event_log_bytes (100)",
                   fn ->
                     Check.relation!(
                       {:at_least, :sse_event_log_session_bytes, :sse_event_log_bytes},
                       opts
                     )
                   end
    end

    test ":at_least accepts a value over the floor and the floor itself" do
      relation = {:at_least, :sse_event_log_session_bytes, :sse_event_log_bytes}

      assert Check.relation!(relation, %{
               sse_event_log_session_bytes: 200,
               sse_event_log_bytes: 100
             }) == :ok

      assert Check.relation!(relation, %{
               sse_event_log_session_bytes: 100,
               sse_event_log_bytes: 100
             }) == :ok
    end
  end

  describe "describe/1" do
    test "a positive integer, with the flags `null` and `infinity`" do
      assert Check.describe(Schema.fetch(:session_timeout_ms)) == "positive integer"
      assert Check.describe(Schema.fetch(:max_sessions)) == "positive integer, or `nil`"

      assert Check.describe(Schema.fetch(:task_default_ttl_ms)) ==
               "positive integer, at most `31536000000`, or `nil`"

      assert Check.describe(Schema.fetch(:task_max_ttl_ms)) ==
               "positive integer, at most `31536000000`, or `nil`"

      assert Check.describe(Schema.fetch(:client_request_timeout_ms)) ==
               "positive integer, or `:infinity`"
    end

    test "a non-negative integer, a boolean and the functions of a module" do
      assert Check.describe(Schema.fetch(:sse_resume_window_ms)) == "non-negative integer"
      assert Check.describe(Schema.fetch(:tasks_follow_session)) == "`true` or `false`"
      assert Check.describe(Schema.fetch(:session_snapshot)) == "the functions"
      assert Check.describe(Schema.fetch(:task_store)) == "the functions"
      assert Check.describe(Schema.fetch(:pubsub)) == "the functions"
    end
  end
end
