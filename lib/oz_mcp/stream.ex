#
# The target of the messages of one request: the stream of a `POST`
# response, or a sink of a transport that has no HTTP response (stdio).
#
# A stream is a struct (see `%OzMcp.PostStream{}`) that the process which
# owns the request carries through its wait. The wait loop
# (`OzMcp.Handler.Invoke`) hands each message of the request to the
# callbacks of this behaviour — `relay/2` for a message that belongs to
# the request, `heartbeat/2` for an idle wait — and each callback returns
# the stream it was given, changed. The owner gives the last stream back
# with the result of the request and the transport closes it with the
# response. `OzMcp.Handler.Invoke` never calls `OzMcp.PostStream`: it
# only knows this behaviour.
#
defmodule OzMcp.Stream do
  @moduledoc false

  @type t :: struct()

  @callback relay(t(), message :: term()) :: t()

  @callback heartbeat(t(), keyword()) :: t()
end
