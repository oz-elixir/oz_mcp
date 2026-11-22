#
# A verifier that reads the `authorization` header with
# `Plug.Conn.get_req_header/2` and never calls `OzMcp.Auth.bearer_token/2`.
# The limit `:max_token_bytes` does not apply to it.
#
defmodule Support.Auth.HandRead do
  @behaviour OzMcp.Auth

  alias OzMcp.Auth.Principal

  @audience "https://mcp.example.com/mcp"

  @impl true
  def authenticate(conn, _server) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> _token] -> {:ok, Principal.new!(subject: "hand-read", audiences: [@audience])}
      _other -> {:error, :missing_token}
    end
  end
end
