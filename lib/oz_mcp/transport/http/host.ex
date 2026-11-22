#
# The `Host` check: the option `allowed_hosts` is `:any` or a list
# (the boot lower-cases the names, so only the host of the request is
# lower-cased here). The comparison runs on `Plug.Conn.host`, which
# holds no port; the host of an IPv6 request keeps its brackets.
#
defmodule OzMcp.Transport.Http.Host do
  @moduledoc false

  @spec allowed?(Plug.Conn.t(), :any | [String.t()]) :: boolean()
  def allowed?(_conn, :any), do: true

  def allowed?(%Plug.Conn{host: host}, hosts) when is_list(hosts),
    do: is_binary(host) and String.downcase(host) in hosts
end
