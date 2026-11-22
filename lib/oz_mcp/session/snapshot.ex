defmodule OzMcp.Session.Snapshot do
  @moduledoc """
  The persistent part of a session, for a restart or a cluster. The
  session process calls the module (the option `:session_snapshot` of
  `OzMcp`). The default `OzMcp.Session.Snapshot.None` keeps nothing.

  A snapshot holds: `principal_key`, `protocol_version`, `client_info`,
  `client_capabilities`, `log_level`, `subscriptions` and the optional
  `subscription_scopes` (the scopes that each subscribed URI needs; the
  key is written only when one URI needs scopes). It does not hold the
  streams, the event log or the requests.

  The calls:

    * `save/3` runs after each persistent change of an initialized
      session that gives a snapshot the session does not hold yet: the
      `initialized` notification, `logging/setLevel` and the
      subscriptions. A change that gives the persistent part of the last
      write calls nothing. The session does not wait for the write: a
      writer process of the instance runs it, so a slow store never
      holds a call or an answer of the session. Two writes for one
      session never run at the same time; a writer keeps only the newest
      snapshot of a session. A stop of the node can lose the last
      change and a crash of the writer loses the writes it holds.
    * `load/2` runs when a request names a session that the instance does
      not know (for example after a restart). It runs in the process of
      that request, before the owner check of the session. The library
      checks the map that the module returns: the keys must be atoms,
      the six keys of the type `snapshot()` must be there (the optional
      `subscription_scopes` key may be there), the values
      must have the types of that type and the protocol version must be
      one that the instance supports. A map of a wrong shape gives an
      unknown session and one warning goes into the log. A loaded
      snapshot starts a session that is already initialized.
    * `delete/2` runs in the writer of the instance after the session
      ended and after a running save of the same session ends (a save
      that takes more than 3 s is stopped). The delete has a time limit
      of 5 s. The session answers the `DELETE` before the delete runs.
      A restore of the id on this node gives an unknown session until
      the delete ends. A failed or a stopped delete keeps the tombstone
      of the id (the mark that refuses a restore) for 60 s and the
      snapshot can stay in the store. A stop of the node can lose a
      queued delete. A session that crashed keeps its snapshot.

  A failure (`{:error, reason}`, a raise, a throw or an exit) of `save/3`
  and `delete/2` writes a log and does not stop the session or the
  writer. The session takes a `save/3` as done when it hands it to the
  writer: a write that failed waits for the next change that gives
  another snapshot. A failure of `load/2` gives an unknown session.
  """

  @type snapshot :: %{
          required(:principal_key) => term(),
          required(:protocol_version) => String.t() | nil,
          required(:client_info) => map() | nil,
          required(:client_capabilities) => map(),
          required(:log_level) => atom() | nil,
          required(:subscriptions) => [String.t()],
          optional(:subscription_scopes) => %{optional(String.t()) => [String.t()]}
        }

  @callback save(instance :: atom(), session_id :: String.t(), snapshot()) ::
              :ok | {:error, term()}

  @callback load(instance :: atom(), session_id :: String.t()) ::
              {:ok, snapshot()} | :not_found | {:error, term()}

  @callback delete(instance :: atom(), session_id :: String.t()) :: :ok
end
