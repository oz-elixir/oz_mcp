#
# The routing rule of a message of a request to the client: the stream
# of the request when it has one, else the first GET stream of the
# session. The client requests guide, section "Where the request
# travels", explains the fallback. `OzMcp.Session.Outbound` and
# `OzMcp.Session.Core` call it in the same step as the message that
# makes the event, so the event is numbered at once.
#
defmodule OzMcp.Session.Route do
  @moduledoc false

  alias OzMcp.Session.{Core, Effect}
  alias OzMcp.Session.Streams.{Get, Post}

  # Sends an encoded message to the stream of a request, or to the session.
  #
  @spec request_or_session(Core.t(), String.t() | integer() | nil, iodata()) ::
          {Core.t(), [Effect.t()]}
  def request_or_session(core, request_id, encoded) do
    case Post.emit_request(core, request_id, encoded) do
      {core, []} -> Get.emit(core, encoded)
      sent -> sent
    end
  end
end
