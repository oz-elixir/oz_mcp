#
# Runs the `roots_list_changed/1` callback of a server when a client sends
# `notifications/roots/list_changed`.
#
# A notification has no answer and no request that bounds the work, so a
# client could send it in a loop. The session bounds the cost:
#
#   * One run per session at a time. The session keeps
#     `roots: %{running: pid | nil, again: boolean}`. The first notification
#     starts the callback of the session under the invoke supervisor; the
#     session monitors it.
#   * Notifications coalesce. Every notification that arrives while the
#     callback runs only marks the session as changed. When the callback
#     ends, it runs once more for all of them, because the roots may have
#     changed after the callback read them. A burst of notifications is
#     therefore at most two runs, never one process per notification.
#   * Other sessions are independent.
#
# The cast is asynchronous and never fails: a session that is gone loses the
# notification.
#
defmodule OzMcp.RootsChanged do
  @moduledoc false

  alias OzMcp.Session

  # Handles one `notifications/roots/list_changed`. `ctx` is the short context
  # of the callbacks (`server`, `session_id`, ...), without a request id.
  #
  # Returns `:ok`. The run of the callback is not awaited: the session decides
  # when it runs.
  #
  @spec trigger(map()) :: :ok
  def trigger(%{session_id: session_id, instance: instance} = ctx) do
    _ = Session.mark_roots_changed(instance, session_id, ctx)
    :ok
  end
end
