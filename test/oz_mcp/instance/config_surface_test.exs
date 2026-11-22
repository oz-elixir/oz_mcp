defmodule OzMcp.Instance.ConfigSurfaceTest do
  use ExUnit.Case, async: true
  alias Support.Servers

  @server Servers.Default

  # One invalid value and the exact message of the boot for each option
  # with a generic type and for each key of the type `:custom` except
  # `resource_url` (the tests of the runtime config already cover it).
  #
  @invalid [
    {:allowed_origins, "https://a.example",
     ~s{allowed_origins must be a list, got: "https://a.example"}},
    {:allowed_hosts, :nope, "allowed_hosts must be :any or a list of host names, got: :nope"},
    {:session_timeout_ms, 0, "session_timeout_ms must be a positive integer (ms), got: 0"},
    {:task_page_size, 0, "task_page_size must be a positive integer, got: 0"},
    {:task_poll_interval_ms, 0,
     "task_poll_interval_ms must be a positive integer (ms) or nil, got: 0"},
    {:task_default_ttl_ms, 0,
     "task_default_ttl_ms must be a positive integer (ms) at most 31536000000 or nil, got: 0"},
    {:task_max_ttl_ms, 0,
     "task_max_ttl_ms must be a positive integer (ms) at most 31536000000 or nil, got: 0"},
    {:request_timeout_ms, -1,
     "request_timeout_ms must be a positive integer (ms) or nil, got: -1"},
    {:request_cancel_grace_ms, 0,
     "request_cancel_grace_ms must be a positive integer (ms), got: 0"},
    {:client_request_timeout_ms, 0,
     "client_request_timeout_ms must be a positive integer (ms) or :infinity, got: 0"},
    {:elicitation_timeout_ms, 0,
     "elicitation_timeout_ms must be a positive integer (ms) or :infinity, got: 0"},
    {:sampling_timeout_ms, 0,
     "sampling_timeout_ms must be a positive integer (ms) or :infinity, got: 0"},
    {:client_task_poll_interval_ms, 0,
     "client_task_poll_interval_ms must be a positive integer, got: 0"},
    {:sse_heartbeat_ms, 0,
     "sse_heartbeat_ms must be a positive integer (ms) or :infinity, got: 0"},
    {:sse_retry_ms, 0, "sse_retry_ms must be a positive integer (ms), got: 0"},
    {:sse_max_stream_ms, 0, "sse_max_stream_ms must be a positive integer (ms) or nil, got: 0"},
    {:sse_event_log_size, 0, "sse_event_log_size must be a positive integer, got: 0"},
    {:sse_event_log_bytes, 0, "sse_event_log_bytes must be a positive integer, got: 0"},
    {:sse_event_log_session_bytes, 0,
     "sse_event_log_session_bytes must be a positive integer, got: 0"},
    {:sse_event_log_max_streams, 0,
     "sse_event_log_max_streams must be a positive integer or nil, got: 0"},
    {:sse_resume_window_ms, -1, "sse_resume_window_ms must be a non-negative integer, got: -1"},
    {:session_init_timeout_ms, 0, "session_init_timeout_ms must be a positive integer, got: 0"},
    {:session_restore_miss_ttl_ms, -1,
     "session_restore_miss_ttl_ms must be a non-negative integer, got: -1"},
    {:max_token_bytes, 0, "max_token_bytes must be a positive integer, got: 0"},
    {:max_body_bytes, 0, "max_body_bytes must be a positive integer, got: 0"},
    {:max_sessions, 0, "max_sessions must be a positive integer or nil, got: 0"},
    {:max_sessions_per_principal, 0,
     "max_sessions_per_principal must be a positive integer or nil, got: 0"},
    {:max_streams_per_session, 0,
     "max_streams_per_session must be a positive integer or nil, got: 0"},
    {:max_subscriptions_per_session, 0,
     "max_subscriptions_per_session must be a positive integer or nil, got: 0"},
    {:max_tasks_per_session, 0,
     "max_tasks_per_session must be a positive integer or nil, got: 0"},
    {:max_tasks_per_principal, 0,
     "max_tasks_per_principal must be a positive integer or nil, got: 0"},
    {:max_task_records_per_owner, 0,
     "max_task_records_per_owner must be a positive integer or nil, got: 0"},
    {:max_task_bytes_per_owner, 0,
     "max_task_bytes_per_owner must be a positive integer (bytes) or nil, got: 0"},
    {:tasks_follow_session, nil, "tasks_follow_session must be a boolean, got: nil"},
    {:client_tasks, nil, "client_tasks must be a boolean, got: nil"},
    {:client_tasks, "yes", ~s{client_tasks must be a boolean, got: "yes"}},
    {:check_results, nil, "check_results must be a boolean, got: nil"},
    {:check_results, "false", ~s{check_results must be a boolean, got: "false"}},
    {:check_output_schemas, nil, "check_output_schemas must be a boolean, got: nil"},
    {:check_output_schemas, "false", ~s{check_output_schemas must be a boolean, got: "false"}},
    {:session_snapshot, @server,
     "server #{inspect(@server)}: the session snapshot module #{inspect(@server)} " <>
       "must export save/3, load/2, delete/2"},
    {:task_store, @server,
     "server #{inspect(@server)}: the task store #{inspect(@server)} " <>
       "must export init/1, put/2, get/2, delete/2"},
    {:pubsub, @server,
     "server #{inspect(@server)}: the pubsub module #{inspect(@server)} " <>
       "must export subscribe/2, unsubscribe/2, broadcast/3"},
    {:telemetry_prefix, [], "telemetry_prefix must be a non-empty list of atoms, got: []"},
    {:telemetry_prefix, [:oz_mcp, "test"],
     "telemetry_prefix must be a non-empty list of atoms, got: [:oz_mcp, \"test\"]"},
    {:allowed_origins, ["*"],
     ~s{allowed_origins: "*" is not a wildcard. Give each origin, } <>
       ~s{for example "https://app.example.com"}},
    {:allowed_origins, [:localhost],
     "allowed_origins must hold non-empty strings, got: :localhost"},
    {:allowed_hosts, [""], ~s{allowed_hosts must hold non-empty strings, got: ""}}
  ]

  for {key, value, message} <- @invalid do
    test "#{key} with #{inspect(value)} stops the boot" do
      assert_raise ArgumentError, unquote(message), fn ->
        OzMcp.Instance.Config.parse!([
          {:server, @server},
          {unquote(key), unquote(Macro.escape(value))}
        ])
      end
    end
  end
end
