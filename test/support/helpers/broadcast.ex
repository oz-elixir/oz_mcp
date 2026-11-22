defmodule Support.Helpers.Broadcast do
  alias OzMcp.Sessions
  alias OzMcp.Utils.JsonRpc

  # One notification to each session of the instance, on the path that the
  # list-changed notifications of Notify used.
  #
  def notify_all(instance) do
    Sessions.notify_all(instance, JsonRpc.notification("notifications/tools/list_changed", nil))
  end
end
