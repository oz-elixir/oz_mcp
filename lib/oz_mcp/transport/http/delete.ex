#
# `OzMcp.Router` forwards the `DELETE` requests of the endpoint to it.
#
# The `DELETE` route: the DELETE stages of the pipeline
# (`OzMcp.Validate.http_delete/1`), then the end of the session with
# `OzMcp.Sessions.terminate/2`. The answer carries no body; a session
# that is already gone gets `404`, an instance that cannot answer
# gets `503`.
#
defmodule OzMcp.Transport.Http.Delete do
  @moduledoc false

  alias OzMcp.Context
  alias OzMcp.Sessions
  alias OzMcp.Transport.Http.Response
  alias OzMcp.Validate

  # The `DELETE` route of the endpoint: the request runs through the
  # DELETE stages of the pipeline and a request that passes ends its
  # session.
  #
  @spec call(Plug.Conn.t()) :: Plug.Conn.t()
  def call(conn) do
    context =
      Context.new(
        conn.private.instance,
        :http_streamable,
        :http,
        conn.private[:oz_mcp_config]
      )
      |> Context.put_http_conn(conn)
      |> Validate.http_delete()
      |> Response.unwrap()

    if context.conn.halted do
      context.conn
    else
      case Sessions.terminate(context.instance, context.session_id) do
        :ok ->
          #
          # No body, no content-type; the headers of the pipeline stay.
          #
          Response.empty(context.conn, 200)

        # The session is already gone.
        #
        {:error, :no_session} ->
          Response.invalid_session(context.conn)

        # The instance cannot answer: the caller may try again.
        #
        {:error, _reason} ->
          Response.unavailable(context.conn)
      end
    end
  end
end
