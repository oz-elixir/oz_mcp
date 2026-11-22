defmodule OzMcp.Instance.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias OzMcp.Instance.Config.Check
  alias OzMcp.Instance.Config.Schema
  alias Support.Servers

  @server Servers.Default

  @defaults %{
    allowed_origins: [],
    allowed_hosts: :any,
    session_timeout_ms: 3_600_000,
    task_page_size: 50,
    task_poll_interval_ms: nil,
    task_default_ttl_ms: nil,
    task_max_ttl_ms: 86_400_000,
    request_timeout_ms: nil,
    request_cancel_grace_ms: 1_000,
    client_request_timeout_ms: 60_000,
    elicitation_timeout_ms: 300_000,
    sampling_timeout_ms: 120_000,
    client_tasks: false,
    client_task_poll_interval_ms: 2_000,
    sse_heartbeat_ms: 15_000,
    sse_retry_ms: 1000,
    sse_max_stream_ms: nil,
    sse_event_log_size: 256,
    sse_event_log_bytes: 1_048_576,
    sse_event_log_session_bytes: 8_388_608,
    sse_event_log_max_streams: 256,
    sse_resume_window_ms: 300_000,
    session_init_timeout_ms: 30_000,
    session_restore_miss_ttl_ms: 5_000,
    max_token_bytes: 8192,
    max_body_bytes: 1_048_576,
    max_sessions: 10_000,
    max_sessions_per_principal: 100,
    max_streams_per_session: 8,
    max_subscriptions_per_session: 1_000,
    max_log_rate: 100,
    max_tasks_per_session: 100,
    max_tasks_per_principal: 1_000,
    max_task_records_per_owner: 1_000,
    max_task_bytes_per_owner: 67_108_864,
    tasks_follow_session: true,
    check_results: true,
    check_output_schemas: true,
    session_snapshot: OzMcp.Session.Snapshot.None,
    task_store: OzMcp.Tasks.EtsStore,
    pubsub: OzMcp.PubSub.Registry,
    telemetry_prefix: [:oz_mcp],
    resource_url: nil
  }

  test "each row has a unique key" do
    keys = Schema.keys()

    assert Enum.uniq(keys) == keys
  end

  test "the default of each row passes its own check and stays the same" do
    for {_key, _type, default, _flags} = row <- Schema.rows() do
      assert Check.value(row, default, @server) == default
    end
  end

  test "defaults/0 gives the default of each row" do
    assert Schema.defaults() == @defaults
  end

  test "fetch/1 gives the row of a key and nil for an unknown key" do
    assert Schema.fetch(:session_timeout_ms) ==
             {:session_timeout_ms, :pos_int, 3_600_000, [unit: "ms"]}

    assert Schema.fetch(:no_such_option) == nil
  end

  test "relations/0 holds the relations" do
    assert Schema.relations() == [
             {:at_most, :task_default_ttl_ms, :task_max_ttl_ms},
             {:at_least, :sse_event_log_session_bytes, :sse_event_log_bytes},
             {:at_most, :max_tasks_per_session, :max_task_records_per_owner},
             {:at_most, :max_tasks_per_principal, :max_task_records_per_owner}
           ]
  end

  describe "task ttl options" do
    test "respects the maximum TTL limit" do
      max_ttl = OzMcp.Tasks.ttl_ceiling_ms()
      assert max_ttl == 31_536_000_000

      assert {:task_default_ttl_ms, :pos_int, nil, flags} = Schema.fetch(:task_default_ttl_ms)
      assert flags[:max] == max_ttl
      assert {:task_max_ttl_ms, :pos_int, 86_400_000, flags} = Schema.fetch(:task_max_ttl_ms)
      assert flags[:max] == max_ttl
    end
  end

  describe "max_log_rate" do
    test "the default is 100" do
      assert {:max_log_rate, :pos_int, 100, flags} = Schema.fetch(:max_log_rate)
      assert flags[:null] == true
      assert flags[:unit] == "messages per second"
    end

    test "a positive integer and nil pass the check" do
      row = Schema.fetch(:max_log_rate)

      assert Check.value(row, 100, @server) == 100
      assert Check.value(row, 1, @server) == 1
      assert Check.value(row, nil, @server) == nil
    end

    test "a value that is not a positive integer or nil stops the boot" do
      row = Schema.fetch(:max_log_rate)

      for invalid <- [0, -1, 1.5, "10", :infinity] do
        assert_raise ArgumentError,
                     "max_log_rate must be a positive integer (messages per second) or nil, " <>
                       "got: #{inspect(invalid)}",
                     fn -> Check.value(row, invalid, @server) end
      end
    end
  end
end
