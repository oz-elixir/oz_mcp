#
# The public view of a session: the value of its Registry entry. Only
# the session process changes it.
#
defmodule OzMcp.Session.View do
  @moduledoc false

  defstruct [
    :pid,
    :principal_key,
    :protocol_version,
    :client_info,
    :last_active_ms,
    initialized: false,
    streams: 0,
    log_level: nil,
    client_capabilities: %{}
  ]

  @type t :: %__MODULE__{}

  @fields [
    :principal_key,
    :protocol_version,
    :client_info,
    :log_level,
    :client_capabilities,
    :initialized
  ]

  # Builds the view from the attributes of a new session and its last activity time.
  #
  @spec new(pid() | nil, map(), integer()) :: t()
  def new(pid, attrs, now) do
    attrs
    |> Map.take(@fields)
    |> Map.put(:pid, pid)
    |> Map.put(:last_active_ms, now)
    |> then(&struct!(__MODULE__, &1))
  end
end
