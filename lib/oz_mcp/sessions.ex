defmodule OzMcp.Sessions do
  @moduledoc """
  The sessions of an instance: start, find, stop.

  Each function takes the instance as its first argument. A call that
  cannot get an answer gives `{:error, :unavailable}` (the instance is
  not running, or the process of the call exited) or `{:error, :timeout}`
  (no answer in time). A session that does not exist gives
  `{:error, :no_session}`.

  A session is a process (OzMcp.Session). It owns its lifecycle: the
  initialization, the idle timer and the end. `lookup/2` reads the public
  view of the session from the Registry of the instance, with no call.
  `set_initialized/2`, `set_log_level/3`, `subscribe/3`, `unsubscribe/3`
  and `terminate/2` call the session process and `touch/2` casts to it. A session that is gone
  gives `{:error, :no_session}`: a request that arrives while the session
  stops cannot see a half-ended session.

  The readers of this module never start a session: only
  `fetch_snapshot/2` and `start_restored/4` take a session out of the
  snapshot store and only the restore stage of the request pipeline
  calls them (see OzMcp.Validate). A message of the server (a
  notification, a request to the client) never starts a session.

  `list_principal/2` and `terminate_principal/2` read the `Principals`
  Registry of the instance. They do not use the PubSub module, so they
  work with a custom module. They are for an administrator, not for a
  request.

  The limit `max_sessions_per_principal` is checked before the start of
  a session and a restore from a snapshot counts in it. Each open session
  registers itself in the `Principals` Registry under the key of its
  principal and the Registry removes the entry when the session process
  ends. The count reads one key, so it does not scan the views. The check
  and the start are two steps: two requests that arrive at the same time
  for two different session ids can pass the check together. The limit
  `max_sessions` is checked at the start itself, so it holds exactly.

  The session process also owns the streams of the session (the GET
  streams, the stdio stream and the POST streams), its event log and the
  requests of the client that run right now. The transports call
  OzMcp.Session for the streams and the requests. The functions with
  `@doc false` are for the framework and the application does not call
  them. A broadcast goes through the pubsub of the instance
  (`OzMcp.PubSub`) to the sessions of a topic.

  `terminate_principal/2` runs the full cascade of the end of a session:
  the streams, the tasks and the requests of the client.
  """

  alias OzMcp.Auth.Guard, as: AuthGuard
  alias OzMcp.Auth.Principal
  alias OzMcp.Instance
  alias OzMcp.Session
  alias OzMcp.Session.RestoreCache
  alias OzMcp.Session.Snapshot.Check
  alias OzMcp.Session.Snapshot.Guard
  alias OzMcp.Session.Snapshot.None
  alias OzMcp.Session.View
  alias OzMcp.Sessions.Reclaim
  alias OzMcp.Telemetry
  alias OzMcp.Utils.Generator
  alias OzMcp.Wire

  require Logger

  @type error :: {:error, :no_session | :unavailable | :timeout | term()}

  @type principal_key :: {String.t() | nil, String.t()}

  @rounds 3

  # A key is {issuer, subject}. The issuer is a string or nil. The subject
  # is a non-empty string: the shape that OzMcp.Auth.Principal.key/1 builds.
  #
  defguardp is_principal_key(key)
            when is_tuple(key) and tuple_size(key) == 2 and
                   (is_binary(elem(key, 0)) or is_nil(elem(key, 0))) and
                   is_binary(elem(key, 1)) and elem(key, 1) != ""

  @doc """
  Starts a session. Returns its id.

  The options are `:protocol_version`, `:client_info`,
  `:client_capabilities`, `:principal_key`, `:transport` (the transport
  of the caller, for the telemetry of the session) and `:config` (the
  config of the request, when the caller already read it: the start then
  reads the Registry no time).

  `{:error, :too_many_sessions}` tells that `max_sessions` or
  `max_sessions_per_principal` is reached.
  """
  @spec start(Instance.t(), keyword()) :: {:ok, String.t()} | error()
  def start(instance, opts \\ []) do
    attrs = %{
      session_id: Generator.session_id(),
      transport: Keyword.get(opts, :transport),
      protocol_version: Keyword.get(opts, :protocol_version),
      client_info: Keyword.get(opts, :client_info),
      client_capabilities: Keyword.get(opts, :client_capabilities, %{}),
      principal_key: Keyword.get(opts, :principal_key)
    }

    with {:ok, config} <- fetch_config(instance, Keyword.get(opts, :config)),
         :ok <-
           principal_limit(
             config.telemetry,
             instance,
             attrs.principal_key,
             config.opts.max_sessions_per_principal,
             nil,
             true
           ),
         {:ok, _pid} <-
           start_process(config.telemetry, config.opts.max_sessions, instance, attrs, true) do
      {:ok, attrs.session_id}
    end
  end

  defp start_process(telemetry, max_sessions, instance, attrs, reclaim?, round \\ 1) do
    case Session.start(instance, attrs) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, _pid}} = taken ->
        taken

      {:error, :max_children} ->
        make_room(telemetry, max_sessions, instance, attrs, reclaim?, round)

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  # The pool is full: end one idle session and try again, at most
  # `@rounds` times. No idle session gives the same refusal as before.
  #
  defp make_room(telemetry, max_sessions, instance, attrs, true, round) when round <= @rounds do
    case Reclaim.run(instance, :instance, attrs.session_id) do
      :ok ->
        Telemetry.limit(telemetry, :max_sessions, max_sessions, :instance, :replaced)
        start_process(telemetry, max_sessions, instance, attrs, true, round + 1)

      :none ->
        refuse(telemetry, max_sessions)
    end
  end

  defp make_room(telemetry, max_sessions, _instance, _attrs, _reclaim?, _round),
    do: refuse(telemetry, max_sessions)

  defp refuse(telemetry, max_sessions) do
    Telemetry.limit(telemetry, :max_sessions, max_sessions, :instance)
    {:error, :too_many_sessions}
  end

  defp fetch_config(instance, config \\ nil) do
    case Instance.config(instance, config) do
      {:ok, config} -> {:ok, config}
      :not_running -> {:error, :unavailable}
    end
  end

  # The count of the sessions of a principal leaves out the session id
  # `except_id`: a restore of an id counts the sessions of the other ids
  # only, because the session of that id either runs already (its view is
  # the answer) or starts with this call. `nil` leaves out nothing: a new
  # session id is never in the Registry. The check and the start are two
  # steps, so two requests for two different ids can pass the check
  # together; the limit `max_sessions` of the supervisor has no such gap.
  #
  defp principal_limit(_telemetry, _instance, _key, nil, _except_id, _reclaim?), do: :ok
  defp principal_limit(_telemetry, _instance, nil, _max, _except_id, _reclaim?), do: :ok

  defp principal_limit(telemetry, instance, key, max, except_id, reclaim?) do
    if principal_full?(instance, key, max, except_id) do
      reclaim_principal(telemetry, instance, key, max, except_id, reclaim?)
    else
      :ok
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  # `lookup/2` reads the entries of one key. Do not use `count_match/4`:
  # it walks the full table. `except_id` is nil for a new id.
  #
  defp principal_full?(instance, key, max, except_id) do
    instance
    |> Instance.principals()
    |> Registry.lookup(key)
    |> Enum.count(fn {_pid, session_id} -> session_id != except_id end)
    |> Kernel.>=(max)
  end

  # Reclaim one idle session of the principal and count again: the scope
  # is small, so one round is enough.
  #
  defp reclaim_principal(telemetry, instance, key, max, except_id, true) do
    case Reclaim.run(instance, {:principal, key}, except_id) do
      :ok ->
        if principal_full?(instance, key, max, except_id) do
          refuse_principal(telemetry, max)
        else
          Telemetry.limit(telemetry, :max_sessions_per_principal, max, :principal, :replaced)
          :ok
        end

      :none ->
        refuse_principal(telemetry, max)
    end
  end

  defp reclaim_principal(telemetry, _instance, _key, max, _except_id, false),
    do: refuse_principal(telemetry, max)

  defp refuse_principal(telemetry, max) do
    Telemetry.limit(telemetry, :max_sessions_per_principal, max, :principal)
    {:error, :too_many_sessions}
  end

  @doc """
  Reads the public view of a session from the Registry. No call. A
  session whose process is dead is unknown, even while the Registry
  still holds its entry.

  `lookup/2` never calls the snapshot module and never starts a session:
  a session that the Registry does not know is unknown, even when the
  snapshot store of the instance holds it. Only the request pipeline
  restores a session, through `fetch_snapshot/2` and `start_restored/4`
  (see `OzMcp.Session.Snapshot`).
  """
  @spec lookup(Instance.t(), String.t()) :: {:ok, View.t()} | error()
  def lookup(instance, session_id) do
    case Registry.lookup(Instance.names(instance), {:session, session_id}) do
      [{pid, %View{} = view}] ->
        if Process.alive?(pid), do: {:ok, view}, else: {:error, :no_session}

      _ ->
        {:error, :no_session}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  # Tells whether the instance can restore a session from a snapshot:
  # `:enabled` (a snapshot module is set), `:disabled` (the module is
  # `OzMcp.Session.Snapshot.None`, the default) or `{:error,
  # :unavailable}` (the instance does not run). The restore stage of the
  # request pipeline reads it before it touches the Registry. A caller
  # that already read the config of the request gives it as the second
  # argument.
  #
  @doc false
  @spec restore_mode(Instance.t(), OzMcp.Instance.Config.t() | nil) ::
          :enabled | :disabled | {:error, :unavailable}
  def restore_mode(instance, config \\ nil) do
    case Instance.config(instance, config) do
      {:ok, config} ->
        if config.opts.session_snapshot == None, do: :disabled, else: :enabled

      :not_running ->
        {:error, :unavailable}
    end
  end

  # Reads the snapshot of a session from the module of the instance and
  # checks its shape. No start of a session, no check of the limits.
  # `:disabled`: the instance has no snapshot module. `{:error, :failed}`:
  # the module failed (an `{:error, _}` answer, a raise, a throw or an
  # exit). `{:error, :invalid}`: the answer of the module is not a
  # snapshot of the right shape.
  #
  # An id whose delete the store has not ended yet is marked as deleted
  # in the instance (a tombstone): the requests for it give `:not_found`
  # with no call to the module, until the delete ends or the hold time
  # of the mark passes.
  #
  # An id that the module did not find stays in the cache of the
  # instance for `session_restore_miss_ttl_ms`: the requests of the same id
  # while the miss is held give `:not_found` with no call to the module.
  # A caller that already read the config of the request gives it as the
  # third argument.
  #
  @doc false
  @spec fetch_snapshot(Instance.t(), String.t(), OzMcp.Instance.Config.t() | nil) ::
          {:ok, map()} | :not_found | :disabled | {:error, :failed | :invalid | :unavailable}
  def fetch_snapshot(instance, session_id, config \\ nil) do
    with {:ok, config} <- fetch_config(instance, config) do
      module = config.opts.session_snapshot

      cond do
        module == None ->
          :disabled

        RestoreCache.deleted?(instance, session_id) ->
          restore_event(config.telemetry, :deleted)
          :not_found

        RestoreCache.missing?(instance, session_id) ->
          restore_event(config.telemetry, :cached_miss)
          :not_found

        true ->
          instance
          |> load_and_cache(module, session_id, config.opts.session_restore_miss_ttl_ms)
          |> restore_outcome(config.telemetry)
      end
    end
  end

  # One event per attempt to read the store. The outcomes of a snapshot
  # that the store holds are emitted by the restore stage of the request
  # pipeline: the attempt goes on until the stage starts the session or
  # refuses.
  #
  defp restore_outcome(:not_found, telemetry) do
    restore_event(telemetry, :miss)
    :not_found
  end

  defp restore_outcome({:error, reason}, telemetry) when reason in [:failed, :invalid] do
    restore_event(telemetry, reason)
    {:error, reason}
  end

  defp restore_outcome(other, _telemetry), do: other

  defp restore_event(telemetry, outcome),
    do: Telemetry.event(telemetry, :session_restore, %{count: 1}, %{outcome: outcome})

  # Only a real miss of the module goes into the cache: a failure can be
  # temporary and a map of a wrong shape is a defect of the store that
  # the next request must report again.
  #
  defp load_and_cache(instance, module, session_id, ttl_ms) do
    case load_snapshot(module, instance, session_id) do
      :not_found ->
        RestoreCache.put_missing(instance, session_id, ttl_ms)
        :not_found

      other ->
        other
    end
  end

  # The answers of `load/2`: a map that passes the check is a snapshot,
  # `:not_found` is a miss, a failure of the module is `{:error, :failed}`
  # and any other answer is `{:error, :invalid}`. The log of an invalid
  # answer holds the shape of the answer, never its content.
  #
  defp load_snapshot(module, instance, session_id) do
    case Guard.call("load", fn -> module.load(instance, session_id) end) do
      {:ok, %{} = snapshot} ->
        check_snapshot(snapshot)

      :not_found ->
        :not_found

      {:error, :failed} ->
        {:error, :failed}

      other ->
        Logger.warning("session snapshot load: invalid answer (#{AuthGuard.shape(other)})")
        {:error, :invalid}
    end
  end

  # A map of the wrong shape is a defect of the store, not of the
  # session: the answer is an unknown session. The log holds the reason
  # atom only, never the map, the id or the principal.
  #
  defp check_snapshot(snapshot) do
    case Check.run(snapshot) do
      {:ok, checked} ->
        {:ok, checked}

      {:error, reason} ->
        Logger.warning("session snapshot load: invalid snapshot (#{reason})")
        {:error, :invalid}
    end
  end

  # Starts a session from a snapshot that the caller checked. A session
  # that another request started first is not started again: its view is
  # the answer. The restore counts in `max_sessions_per_principal` as a
  # start does. The options `principal_limit: false` and `reclaim: false`
  # skip the count and the reclaim: the caller that ends the restored
  # session at once (the DELETE route) holds no slot and it must not end
  # another session. The option `config:` gives the config of the request:
  # the start then reads the Registry no time.
  #
  @doc false
  @spec start_restored(Instance.t(), String.t(), map(), keyword()) ::
          {:ok, View.t()} | error()
  def start_restored(instance, session_id, snapshot, opts \\ []) do
    attrs =
      snapshot
      |> Map.take([
        :principal_key,
        :protocol_version,
        :client_info,
        :client_capabilities,
        :log_level,
        :subscriptions,
        :subscription_scopes
      ])
      |> Map.merge(%{
        session_id: session_id,
        initialized: true,
        transport: :http_streamable
      })

    reclaim? = Keyword.get(opts, :reclaim, true)

    with {:ok, config} <- fetch_config(instance, Keyword.get(opts, :config)),
         :ok <-
           principal_limit(
             config.telemetry,
             instance,
             attrs.principal_key,
             limit(config, opts),
             session_id,
             reclaim?
           ) do
      case start_process(
             config.telemetry,
             config.opts.max_sessions,
             instance,
             attrs,
             reclaim?
           ) do
        {:ok, _pid} -> view(instance, session_id)
        {:error, {:already_started, _pid}} -> view(instance, session_id)
        error -> error
      end
    end
  end

  # `false` is "no limit": the same answer as a `max_sessions_per_principal`
  # of nil.
  #
  defp limit(config, opts) do
    if Keyword.get(opts, :principal_limit, true),
      do: config.opts.max_sessions_per_principal,
      else: nil
  end

  # The view of a session of the Registry: no call, no start.
  #
  defp view(instance, session_id) do
    case Registry.lookup(Instance.names(instance), {:session, session_id}) do
      [{_pid, %View{} = view}] -> {:ok, view}
      _ -> {:error, :no_session}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  @doc """
  Marks the session as active now: its idle timer starts again.

  `granted` is the list of the scopes of the principal of the request, or
  `nil` when there is nothing to check. A list ends the subscriptions of
  the session whose required scopes the list does not cover.
  """
  @spec touch(Instance.t(), String.t()) :: :ok | error()
  def touch(instance, session_id), do: touch(instance, session_id, nil)

  @spec touch(Instance.t(), String.t(), [String.t()] | nil) :: :ok | error()
  def touch(instance, session_id, granted) do
    with {:ok, _view} <- lookup(instance, session_id),
         do: Session.touch(instance, session_id, granted)
  end

  @doc """
  Ends a session: its streams, its tasks and its requests.
  """
  @spec terminate(Instance.t(), String.t()) :: :ok | error()
  def terminate(instance, session_id), do: Session.close(instance, session_id)

  @doc """
  Ends every session of a principal. Returns the ids of the sessions that
  this call ended.

  The principal is an `OzMcp.Auth.Principal` or its key
  `{issuer, subject}`.

  The cascade is the one of `terminate/2`: the open streams get a final
  `retry:` event, the requests in flight are cancelled, the requests to
  the client get `{:error, :session_terminated}` and the tasks are
  removed. The removal of the tasks is asynchronous: it can end a short
  time after this function returns.
  """
  @spec terminate_principal(Instance.t(), Principal.t() | principal_key()) ::
          {:ok, [String.t()]} | error()
  def terminate_principal(instance, %Principal{} = principal),
    do: terminate_principal(instance, Principal.key(principal))

  def terminate_principal(instance, principal_key) when is_principal_key(principal_key) do
    with {:ok, config} <- fetch_config(instance) do
      #
      # The ids come from the Principals Registry, not from the topic of
      # the PubSub module: a custom module can keep its own subscribers
      # and a revocation must not depend on it.
      #
      # A session that its idle timer or a DELETE ended since the read
      # gives `{:error, :no_session}`. It is gone, which is the goal.
      #
      ids = list_principal_ids(instance, principal_key)
      ended = for(id <- ids, terminate(instance, id) == :ok, do: id)

      # One event per revocation, with the count of the sessions this
      # call ended. The key of the principal never goes out.
      #
      Telemetry.event(config.telemetry, :principal_revoked, %{sessions: length(ended)}, %{})

      {:ok, ended}
    end
  end

  @doc """
  The ids of the open sessions of a principal. `nil` gives an empty list.
  """
  @spec list_principal(Instance.t(), Principal.t() | principal_key() | nil) ::
          {:ok, [String.t()]} | error()
  def list_principal(instance, %Principal{} = principal),
    do: list_principal(instance, Principal.key(principal))

  def list_principal(instance, principal_key)
      when is_nil(principal_key) or is_principal_key(principal_key) do
    with {:ok, _config} <- fetch_config(instance),
         do: {:ok, list_principal_ids(instance, principal_key)}
  end

  defp list_principal_ids(_instance, nil), do: []

  defp list_principal_ids(instance, key) do
    instance
    |> Instance.principals()
    |> Registry.lookup(key)
    |> Enum.map(fn {_pid, session_id} -> session_id end)
  rescue
    ArgumentError -> []
  end

  @doc """
  Marks the session as initialized.
  """
  @spec set_initialized(Instance.t(), String.t()) :: :ok | error()
  def set_initialized(instance, session_id), do: Session.initialized(instance, session_id)

  @doc """
  Sets the log level of the session.
  """
  @spec set_log_level(Instance.t(), String.t(), atom()) :: :ok | error()
  def set_log_level(instance, session_id, level),
    do: Session.update_view(instance, session_id, log_level: level)

  @doc """
  Subscribes the session to a resource.

  A repeat subscribe of a URI that is already in the set gives `:ok`. A
  new URI over `max_subscriptions_per_session` gives
  `{:error, :too_many_subscriptions}`.

  `required` is the list of the scopes that the resource needs. The
  session keeps it and a later touch that shows a principal without
  those scopes ends the subscription.
  """
  @spec subscribe(Instance.t(), String.t(), String.t()) :: :ok | error()
  def subscribe(instance, session_id, uri), do: subscribe(instance, session_id, uri, [])

  @spec subscribe(Instance.t(), String.t(), String.t(), [String.t()]) :: :ok | error()
  def subscribe(instance, session_id, uri, required) do
    Session.subscribe(instance, session_id, uri, required)
  end

  @doc """
  Removes the subscription of the session to a resource.
  """
  @spec unsubscribe(Instance.t(), String.t(), String.t()) :: :ok | error()
  def unsubscribe(instance, session_id, uri) do
    Session.unsubscribe(instance, session_id, uri)
  end

  # Sends a message to a stream of a session. `target` is
  # `{:request, request_id}`, `{:request_or_session, request_id}` (a
  # request with no stream sends to the GET stream), `{:stream, stream_id}`
  # (the entry of that stream id, whatever request holds it: the stream of
  # a `tasks/result` request, for example) or `:session`. The message is a
  # map (encoded here, in the caller) or JSON text. The session logs the
  # event and assigns its id. When no GET stream is open, the message
  # waits in a stream that the session makes for it: the first GET that
  # opens gets it.
  #
  @doc false
  @spec emit(
          Instance.t(),
          String.t(),
          {:request | :request_or_session, String.t() | integer() | nil}
          | {:stream, String.t()}
          | :session,
          map() | iodata()
        ) :: :ok | error() | {:error, :not_encodable}
  def emit(instance, session_id, target, message) do
    with {:ok, encoded} <- encode(message),
         do: Session.emit(instance, session_id, target, encoded)
  end

  # Sends a progress report to a stream of a session. The message is
  # encoded here, in the caller and the raw `token` and `value` travel
  # next to it: the session checks that the value increases before it
  # emits the message.
  #
  @doc false
  @spec emit_progress(
          Instance.t(),
          String.t(),
          {:request_or_session, String.t() | integer() | nil} | :session,
          term(),
          term(),
          map()
        ) :: :ok | error() | {:error, :not_encodable}
  def emit_progress(instance, session_id, target, token, value, message) do
    with {:ok, encoded} <- encode(message),
         do: Session.emit_progress(instance, session_id, target, token, value, encoded)
  end

  # Like emit/4, for a notifications/message that the level filter
  # accepted: the session checks the log rate before it emits. A message
  # over the rate is dropped and the return is still `:ok`.
  #
  @doc false
  @spec emit_log(
          Instance.t(),
          String.t(),
          {:request | :request_or_session, String.t() | integer() | nil}
          | {:stream, String.t()}
          | :session,
          map() | iodata()
        ) :: :ok | error() | {:error, :not_encodable}
  def emit_log(instance, session_id, target, message) do
    with {:ok, encoded} <- encode(message),
         do: Session.emit_log(instance, session_id, target, encoded)
  end

  # Cancels a registered request: the session sends
  # `{:oz_mcp_cancel, request_id, reason}` to its owner. A request that
  # already ended or an unknown id is ignored: a cancel is best effort.
  # The reason is free text from the client: it is bounded and made valid
  # UTF-8 before it reaches a log line or an exit signal.
  #
  @doc false
  @spec cancel(Instance.t(), String.t(), String.t() | integer(), term()) :: :ok | error()
  def cancel(instance, session_id, request_id, reason),
    do: Session.cancel(instance, session_id, request_id, clean_reason(reason))

  # A request the session sends to the client (see `OzMcp.Outbound`). The
  # waiter is the process that waits for the answer: the session stores the
  # request, routes its first message and gives the id the client answers
  # and its own pid, so the waiter can monitor the session. The route is
  # `{:request, request_id}` (the stream of a request of the client). A
  # request of a task does not travel through the session: the process of
  # the task holds it.
  #
  @doc false
  @spec request_client(
          Instance.t(),
          String.t(),
          {:request, String.t() | integer() | nil},
          {String.t(), map() | nil}
        ) ::
          {:ok, String.t(), pid()}
          | {:error,
             :session_terminated
             | :no_session
             | :unavailable
             | :timeout
             | :not_encodable
             | :badarg}
  def request_client(instance, session_id, route, {method, params})
      when is_binary(method) and is_tuple(route) and tuple_size(route) == 2 do
    Session.request_client(instance, session_id, route, self(), method, params)
  end

  # Hands the answer of the client to the process that waits for it. The
  # answer travels to the session of the request: a session that is gone
  # loses it (a late answer is not an error).
  #
  @doc false
  @spec deliver(Instance.t(), String.t(), String.t(), {:ok, map()} | {:error, term()}) :: :ok
  def deliver(instance, session_id, out_id, outcome) when is_tuple(outcome) do
    _ = Session.deliver_outbound(instance, session_id, out_id, outcome)
    :ok
  end

  # The cancel reason and the request id come from the client. They are cut
  # to this size (bytes) before they reach a log line or an exit signal.
  #
  @max_client_bytes 200

  defp clean_reason(reason) when is_binary(reason) do
    reason
    |> binary_part(0, min(byte_size(reason), @max_client_bytes))
    |> String.replace_invalid("")
  end

  defp clean_reason(_reason), do: nil

  # `{:ok, %{initialized: boolean, client_capabilities: map,
  #   principal_key: {issuer, subject} | nil,
  #   protocol_version: String.t() | nil}}`: what the validation needs
  # to know about the session of a request, in one read.
  #
  @doc false
  @spec state(Instance.t(), String.t()) :: {:ok, map()} | error()
  def state(instance, session_id) do
    with {:ok, view} <- lookup(instance, session_id) do
      {:ok,
       %{
         initialized: view.initialized,
         client_capabilities: view.client_capabilities,
         principal_key: view.principal_key,
         protocol_version: view.protocol_version
       }}
    end
  end

  # What decides whether a message for the session can reach the client:
  # `{:ok, %{initialized: boolean, stream?: boolean, log_level: atom | nil}}`.
  # `stream?` tells if a GET stream is open. `log_level` is the level that
  # the client set with logging/setLevel (nil before): the log forms of
  # OzMcp.Notify read it in the caller, because a log on the stream of a
  # POST request does not go through the session.
  #
  @doc false
  @spec delivery(Instance.t(), String.t()) :: {:ok, map()} | error()
  def delivery(instance, session_id) do
    with {:ok, view} <- lookup(instance, session_id) do
      {:ok,
       %{initialized: view.initialized, stream?: view.streams > 0, log_level: view.log_level}}
    end
  end

  @doc false
  @spec client_capabilities(Instance.t(), String.t()) :: {:ok, map()} | error()
  def client_capabilities(instance, session_id) do
    case lookup(instance, session_id) do
      {:ok, view} -> {:ok, view.client_capabilities}
      error -> error
    end
  end

  @doc false
  @spec notify_all(Instance.t(), map()) :: :ok | error() | {:error, :not_encodable}
  def notify_all(instance, rpc_notification),
    do: broadcast(instance, :initialized, nil, rpc_notification)

  @doc false
  @spec notify_subscribers(Instance.t(), String.t(), map()) ::
          :ok | error() | {:error, :not_encodable}
  def notify_subscribers(instance, uri, rpc_notification),
    do: broadcast(instance, {:subscription, uri}, nil, rpc_notification)

  # A broadcast of notifications/message. `principal_key` nil sends to
  # every initialized session of the instance (every tenant). A key
  # `{issuer, subject}` sends to the sessions of that principal only. The
  # session filters the log level.
  #
  @doc false
  @spec notify_log_message(Instance.t(), atom(), map(), principal_key() | nil) ::
          :ok | error() | {:error, :not_encodable}
  def notify_log_message(instance, level, rpc_notification, principal_key \\ nil)
      when is_nil(principal_key) or is_principal_key(principal_key) do
    topic = if principal_key, do: {:principal, principal_key}, else: :initialized
    broadcast(instance, topic, {:log, level}, rpc_notification)
  end

  # A notification to the sessions of one principal (the topic of the
  # principal). `filter` is nil, or `{:log, level}` for a log: each
  # session of the topic applies its own level.
  #
  @doc false
  @spec notify_principal(Instance.t(), principal_key(), map(), nil | {:log, atom()}) ::
          :ok | error() | {:error, :not_encodable}
  def notify_principal(instance, principal_key, rpc_notification, filter \\ nil)
      when is_principal_key(principal_key),
      do: broadcast(instance, {:principal, principal_key}, filter, rpc_notification)

  # The message is encoded one time, here. Each session gets the encoded
  # message from the pubsub of the instance.
  #
  defp broadcast(instance, topic, filter, rpc_notification) do
    with {:ok, encoded} <- encode(rpc_notification),
         {:ok, config} <- fetch_config(instance) do
      config.opts.pubsub.broadcast(instance, topic, {:session_event, filter, encoded})
    end
  end

  defp encode(message) when is_map(message), do: Wire.encode_message(message)
  defp encode(message), do: {:ok, message}
end
