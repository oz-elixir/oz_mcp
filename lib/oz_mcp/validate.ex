#
# The stages that check one message before OzMcp.Handler runs it. Each
# stage is a `{module, function}` pair that answers `{:cont, context}` or
# `{:halt, context}`; no stage answers the client.
#
defmodule OzMcp.Validate do
  @moduledoc false

  alias OzMcp.Pipeline
  alias OzMcp.Pipeline.Bind
  alias OzMcp.Validate.{Http, JsonRpc, Stdio}

  @http_post_stages [
    {Http, :auth},
    {Http, :headers},
    {JsonRpc, :validate},
    {Http, :authorize_initialize},
    {Http, :session_id},
    {Http, :protocol_version},
    {Http, :restore},
    {Http, :session},
    {Bind, :run},
    {Http, :required_scopes},
    {Http, :authorize}
  ]

  # The stages of the POST pipeline, in their order.
  #
  # No stage creates a session: the `initialize` handler does. `bind/1`
  # must come after `session/1` and before `required_scopes/1`.
  #
  @spec http_post_stages() :: [Pipeline.stage()]
  def http_post_stages, do: @http_post_stages

  # Run the POST pipeline on a context with the connection.
  #
  @spec http_post(OzMcp.Context.t()) :: Pipeline.result()
  def http_post(context), do: Pipeline.run(context, @http_post_stages)

  @http_get_stages [
    {Http, :auth},
    {Http, :sse_header},
    {Http, :session_id},
    {Http, :protocol_version},
    {Http, :restore},
    {Http, :session}
  ]

  # The stages of the GET pipeline, in their order. A GET stream carries no
  # JSON-RPC message and no entity.
  #
  @spec http_get_stages() :: [Pipeline.stage()]
  def http_get_stages, do: @http_get_stages

  # Run the GET pipeline on a context with the connection.
  #
  @spec http_get(OzMcp.Context.t()) :: Pipeline.result()
  def http_get(context), do: Pipeline.run(context, @http_get_stages)

  @http_delete_stages [
    {Http, :auth},
    {Http, :session_id},
    {Http, :protocol_version},
    {Http, :restore},
    {Http, :session_owner}
  ]

  # The stages of the DELETE pipeline, in their order. A DELETE needs no
  # initialized session: `session_owner/1` replaces the state check.
  #
  @spec http_delete_stages() :: [Pipeline.stage()]
  def http_delete_stages, do: @http_delete_stages

  # Run the DELETE pipeline on a context with the connection.
  #
  @spec http_delete(OzMcp.Context.t()) :: Pipeline.result()
  def http_delete(context), do: Pipeline.run(context, @http_delete_stages)

  @stdio_stages [
    {JsonRpc, :validate},
    {Stdio, :session_id},
    {Stdio, :session}
  ]

  # The stages of the stdio pipeline, in their order. It has no
  # authentication, headers, scopes or authorization: stdio has no
  # principal. The bind runs after these stages, in the process of the
  # message (`stdio_bind/1`).
  #
  @spec stdio_stages() :: [Pipeline.stage()]
  def stdio_stages, do: @stdio_stages

  # Run the stdio pipeline on a context with the message (`Context.put_rpc/2`).
  #
  @spec stdio(OzMcp.Context.t()) :: Pipeline.result()
  def stdio(context), do: Pipeline.run(context, @stdio_stages)

  # Run the bind stage of the stdio pipeline on a context.
  #
  @spec stdio_bind(OzMcp.Context.t()) :: Pipeline.result()
  def stdio_bind(context), do: Pipeline.run(context, [{Bind, :run}])
end
