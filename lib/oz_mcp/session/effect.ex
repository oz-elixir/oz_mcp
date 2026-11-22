#
# The effects that a pure function of the core gives back: they are
# data and `OzMcp.Session.Effects` is the only module that runs them.
#
defmodule OzMcp.Session.Effect do
  @moduledoc false

  @type tag ::
          :roots
          | {:get, String.t()}
          | {:owner, String.t()}
          | {:resumer, String.t()}
          | {:request, String.t() | integer()}
          | {:outbound, String.t()}

  @type t ::
          {:reply, term()}
          | {:next_state, :ready | :closing}
          | {:stop, term()}
          | {:next_event, :internal, term()}
          | {:send, pid(), term()}
          | {:monitor, pid(), tag()}
          | {:demonitor, tag()}
          | {:timeout, name :: term(), ms :: non_neg_integer() | :cancel, content :: term()}
          | {:send_after, non_neg_integer(), term()}
          | {:kill_after, non_neg_integer(), pid()}
          | {:exit, pid(), term()}
          | {:view, OzMcp.Session.View.t()}
          | {:pubsub, :subscribe | :unsubscribe, term()}
          | {:snapshot, :save, map()}
          | {:snapshot, :delete}
          | {:tombstone, String.t()}
          | {:unregister, :names | :principals}
          | {:telemetry, atom(), map(), map()}
          | {:span_stop, term()}
          | {:limit, atom(), term()}
          | {:limit, atom(), term(), :refused | :replaced}
          | {:log, :warning | :debug, String.t()}
          | {:start_roots, map()}
          | {:end_tasks, MapSet.t()}
          | :idle_check
end
