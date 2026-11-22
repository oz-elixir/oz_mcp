defmodule Support.Helpers.SessionLeak do
  alias OzMcp.Session.EventLog
  alias Support.Helpers.EventLogProbe
  alias Support.Helpers.SessionProbe

  # A summary of the state of a session process. A session with no live
  # stream and no pending request must go back to its idle size: the log
  # keeps no ring of an ended stream and the maps are empty.
  #
  @spec snapshot(pid()) :: %{
          log_streams: MapSet.t(),
          log_bytes: non_neg_integer(),
          streams: non_neg_integer(),
          closed_gets: non_neg_integer(),
          requests: non_neg_integer(),
          outbound: non_neg_integer(),
          refs: non_neg_integer()
        }
  def snapshot(pid) do
    {_state_name, core} = SessionProbe.core(pid)

    %{
      log_streams: core.log |> EventLog.streams() |> MapSet.new(),
      log_bytes: EventLogProbe.total_bytes(core.log),
      streams: map_size(core.streams),
      closed_gets: length(core.closed_gets),
      requests: map_size(core.requests),
      outbound: map_size(core.outbound),
      refs: map_size(core.refs)
    }
  end
end
