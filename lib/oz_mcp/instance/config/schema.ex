#
# The table of the options of a server.
#
# One row holds the key, the type, the default value and the flags of one
# option. The `Check` module of the same folder checks a value against
# the type of its row.
#
# The order of the rows is the order of the checks at boot: when two
# options are wrong at the same time, the boot reports the option that
# comes first in the table.
#
defmodule OzMcp.Instance.Config.Schema do
  @moduledoc false

  @type type ::
          :pos_int
          | :non_neg_int
          | :boolean
          | :custom
          | {:module, label :: String.t(), required :: keyword()}

  @type row :: {key :: atom(), type(), default :: term(), flags :: keyword()}

  @snapshot_functions [save: 3, load: 2, delete: 2]
  @pubsub_functions [subscribe: 2, unsubscribe: 2, broadcast: 3]

  # The four required callbacks of the task store contract. The five
  # optional index callbacks (`page/4`, `count_active/2`, `expired/3`,
  # `next_expiry/1`, `owner_usage/2`) are not part of the boot check of
  # the required functions: the boot checks them as one set (all
  # present or all absent) in the check of the option itself.
  #
  @required_task_store_functions [
    init: 1,
    put: 2,
    get: 2,
    delete: 2
  ]

  # The three default modules are named with their full name and joined
  # at compile time. An alias in this table would give this module a
  # compile edge to each of them and the three modules take part in the
  # big compile cycle of the project: the table would grow that cycle by
  # one module. The tests read the same names and catch a mistake.
  #
  @rows [
    {:allowed_origins, :custom, [], []},
    {:allowed_hosts, :custom, :any, []},
    {:session_timeout_ms, :pos_int, 3_600_000, [unit: "ms"]},
    {:task_page_size, :pos_int, 50, []},
    {:task_poll_interval_ms, :pos_int, nil, [unit: "ms", null: true]},
    {:task_default_ttl_ms, :pos_int, nil, [unit: "ms", null: true, max: 31_536_000_000]},
    {:task_max_ttl_ms, :pos_int, 86_400_000, [unit: "ms", null: true, max: 31_536_000_000]},
    {:request_timeout_ms, :pos_int, nil, [unit: "ms", null: true]},
    {:request_cancel_grace_ms, :pos_int, 1_000, [unit: "ms"]},
    {:client_request_timeout_ms, :pos_int, 60_000, [unit: "ms", infinity: true]},
    {:elicitation_timeout_ms, :pos_int, 300_000, [unit: "ms", infinity: true]},
    {:sampling_timeout_ms, :pos_int, 120_000, [unit: "ms", infinity: true]},
    {:client_tasks, :boolean, false, []},
    {:client_task_poll_interval_ms, :pos_int, 2_000, []},
    #
    # The default is 15 s: it stays well under the 60 s idle timeout of
    # many proxies and of Cowboy and on Bandit a gone client is found
    # within one to two heartbeat intervals. The measure of the heartbeat
    # cost (the script of the benchmark folder) shows a scheduler
    # utilization of about 0.2 % at 5,000 idle streams at this interval.
    #
    {:sse_heartbeat_ms, :pos_int, 15_000, [unit: "ms", infinity: true]},
    {:sse_retry_ms, :pos_int, 1000, [unit: "ms"]},
    {:sse_max_stream_ms, :pos_int, nil, [unit: "ms", null: true]},
    {:sse_event_log_size, :pos_int, 256, []},
    {:sse_event_log_bytes, :pos_int, 1_048_576, []},
    {:sse_event_log_session_bytes, :pos_int, 8_388_608, []},
    {:sse_event_log_max_streams, :pos_int, 256, [null: true]},
    {:sse_resume_window_ms, :non_neg_int, 300_000, []},
    {:session_init_timeout_ms, :pos_int, 30_000, []},
    {:session_restore_miss_ttl_ms, :non_neg_int, 5_000, []},
    {:max_token_bytes, :pos_int, 8192, []},
    {:max_body_bytes, :pos_int, 1_048_576, []},
    {:max_sessions, :pos_int, 10_000, [null: true]},
    {:max_sessions_per_principal, :pos_int, 100, [null: true]},
    {:max_streams_per_session, :pos_int, 8, [null: true]},
    {:max_subscriptions_per_session, :pos_int, 1_000, [null: true]},
    {:max_log_rate, :pos_int, 100, [unit: "messages per second", null: true]},
    {:max_tasks_per_session, :pos_int, 100, [null: true]},
    {:max_tasks_per_principal, :pos_int, 1_000, [null: true]},
    {:max_task_records_per_owner, :pos_int, 1_000, [null: true]},
    {:max_task_bytes_per_owner, :pos_int, 67_108_864, [unit: "bytes", null: true]},
    {:tasks_follow_session, :boolean, true, []},
    {:check_results, :boolean, true, []},
    {:check_output_schemas, :boolean, true, []},
    {:session_snapshot, {:module, "session snapshot module", @snapshot_functions},
     Module.concat(["OzMcp", "Session", "Snapshot", "None"]), []},
    {:task_store, {:module, "task store", @required_task_store_functions},
     Module.concat(["OzMcp", "Tasks", "EtsStore"]), []},
    {:pubsub, {:module, "pubsub module", @pubsub_functions},
     Module.concat(["OzMcp", "PubSub", "Registry"]), []},
    {:telemetry_prefix, :custom, [:oz_mcp], []},
    {:resource_url, :custom, nil, []}
  ]

  # A relation compares two options. It applies only when both values
  # are integers (`nil` is a valid value of the keys of `:at_most`).
  #
  @relations [
    {:at_most, :task_default_ttl_ms, :task_max_ttl_ms},
    {:at_least, :sse_event_log_session_bytes, :sse_event_log_bytes},
    {:at_most, :max_tasks_per_session, :max_task_records_per_owner},
    {:at_most, :max_tasks_per_principal, :max_task_records_per_owner}
  ]

  # All the rows, in the order of the checks at boot.
  #
  @spec rows() :: [row()]
  def rows, do: @rows

  # The keys of the rows, in the order of the rows.
  #
  @spec keys() :: [atom()]
  def keys, do: Enum.map(@rows, &elem(&1, 0))

  # The default value of each key.
  #
  @spec defaults() :: map()
  def defaults, do: Map.new(@rows, fn {key, _type, default, _flags} -> {key, default} end)

  # The row of a key, or `nil` when the table does not know the key.
  #
  @spec fetch(atom()) :: row() | nil
  def fetch(key), do: Enum.find(@rows, &(elem(&1, 0) == key))

  # The relations between two options.
  #
  @spec relations() :: [tuple()]
  def relations, do: @relations
end
