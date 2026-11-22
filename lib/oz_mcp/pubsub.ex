defmodule OzMcp.PubSub do
  @moduledoc """
  The broadcast of the session notifications. The default implementation
  (`OzMcp.PubSub.Registry`) uses a `Registry` of the instance. The option
  `:pubsub` of `OzMcp` gives the module. A custom module can send the
  messages through another system. OzMcp also has `OzMcp.PubSub.PG`,
  which uses `:pg` and reaches the sessions of the connected nodes.

  A session subscribes itself to its topics:

    * `:initialized` - each initialized session
    * `{:subscription, uri}` - the sessions that subscribed to the resource
    * `{:principal, key}` - the sessions of one principal

  The subscriber process gets the message `{:oz_mcp_broadcast, message}`.

  The module only sends messages. OzMcp never asks the module for the list
  of the subscribers. `OzMcp.Sessions.list_principal/2` and
  `OzMcp.Sessions.terminate_principal/2` read the sessions of the instance,
  so the revocation of a principal works with any module.
  """

  @type topic :: :initialized | {:subscription, String.t()} | {:principal, term()}

  @doc "Subscribes the calling process to the topic."
  @callback subscribe(instance :: atom(), topic()) :: :ok

  @doc "Removes the subscription of the calling process to the topic."
  @callback unsubscribe(instance :: atom(), topic()) :: :ok

  @doc "Sends the message to each subscriber of the topic."
  @callback broadcast(instance :: atom(), topic(), message :: term()) :: :ok

  @doc """
  The child specs that the module needs. The instance starts them in the
  `PubSub` supervisor, between `Core` and `Workers`. A crash of one of
  them restarts `PubSub` and `Workers`: all the sessions stop and the
  task records stay.

  The module `OzMcp.PubSub.Registry` needs none.
  `OzMcp.PubSub.PG` starts the `:pg` scope of the instance.
  """
  @callback child_specs(instance :: atom()) :: [Supervisor.child_spec()]

  @optional_callbacks child_specs: 1
end
