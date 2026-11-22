#
# A host plug that mounts the MCP endpoint of the server under test on
# the path `/mcp`. The host server gives the `:instance` option to
# `init/1` at the start of the listener and the endpoint reads it on
# every request.
#
defmodule OzMcp.E2E.Router do
  import Plug.Conn, only: [send_resp: 3]

  def init(opts), do: OzMcp.Router.init(opts)

  def call(%Plug.Conn{path_info: ["mcp" | rest]} = conn, opts) do
    OzMcp.Router.call(%{conn | path_info: rest}, opts)
  end

  # The Protected Resource Metadata document sits at the root of the host,
  # outside the MCP endpoint. The forward strips the well-known prefix:
  # the plug receives the segments of the `:resource_url` path.
  #
  def call(
        %Plug.Conn{path_info: [".well-known", "oauth-protected-resource" | rest]} = conn,
        opts
      ) do
    instance = Keyword.fetch!(opts, :instance)

    OzMcp.Auth.Metadata.call(
      %{conn | path_info: rest},
      OzMcp.Auth.Metadata.init(instance: instance)
    )
  end

  def call(conn, _opts), do: send_resp(conn, 404, "not found")
end
