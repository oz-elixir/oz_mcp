defmodule OzMcp.Notify do
  @moduledoc """
  The notifications that a server sends to its clients.

  ## Scope

  Each function sends to a fixed set of sessions:

  | Function | Sessions |
  |---|---|
  | `log/4` | the session of the request of the ctx (the stream of the request); for the ctx of a task, the owner of the task |
  | `log_session/5` | one session |
  | `broadcast_log/4` | every session of the server (every tenant), or the sessions of one principal with `:principal` |
  | `progress/3` | the session of the request of the ctx; for the ctx of a task, the owner of the task |
  | `task_status/3`, `task_progress/7`, `elicitation_complete/3` | one session (`elicitation_complete/3` with the id of a task: the owner of the task) |
  | `resource_updated/3` | the sessions that subscribed to the URI |

  The owner of a task is the principal that created it, or its session
  when the server has no authorization. A message of a task goes to the
  attached `tasks/result` streams of the task, else to every session of
  the owner. A task that a session owns sends only to its session: no
  other session can read the task.

  Do not put the data of one client in a message that goes to many
  sessions.

  ## Data

  The application data of a notification (the `data` of a log, a `_meta`
  map, the `message` of a progress notification) must hold JSON terms:
  strings, numbers, booleans, `nil`, lists and maps with atom or string
  keys. A pid, a tuple, a reference, a function or a port is not a JSON
  term.

  The log functions check the data before the send. They return
  `{:error, :not_encodable}` and send nothing when the data holds a term
  that is not a JSON term. A struct is not a JSON term: convert it first.

  The sender encodes each notification one time, before it sends it. A
  notification that holds a term that JSON cannot encode is not sent and
  the function returns `{:error, :not_encodable}`. The process that writes
  a stream never encodes a term of an application.

  The guide about the notifications shows each function with an
  example: [Notifications](guides/runtime/notifications.md).
  """

  alias OzMcp.Auth.Principal
  alias OzMcp.Config.DSL.Rules
  alias OzMcp.{Context, PostStream, Sessions, Tasks}
  alias OzMcp.LogLevel
  alias OzMcp.Structs.Task
  alias OzMcp.Tasks.RelatedTask
  alias OzMcp.Utils.JsonRpc
  alias OzMcp.Wire

  require LogLevel
  require Logger

  @doc """
  Sends `notifications/message` to many sessions of the server.

  WARNING: without the `:principal` option, the message goes to every
  initialized session of the server, thus to every tenant. Do not put the
  data of one client in a broadcast. For a message about a request, use
  `log/4` with the ctx of the request. For one session, use
  `log_session/5`.

  Options:

    * `:logger` - the name of the logger (a string).
    * `:principal` - an `OzMcp.Auth.Principal` or a key `{issuer, subject}`.
      The message goes only to the sessions of that principal.

  Each session gets the message only when its level (`logging/setLevel`)
  accepts the level of the message. A message over the option
  `max_log_rate` of the instance is dropped by the session: the return
  stays `:ok`. Returns `{:error, :not_encodable}`
  when the data holds a term that is not a JSON term: nothing is sent.
  Returns `{:error, :unavailable}` when the instance does not run.
  """
  @spec broadcast_log(module(), LogLevel.t(), term(), keyword()) ::
          :ok | {:error, :not_encodable | :unavailable}
  def broadcast_log(instance, level, data, opts \\ [])
      when is_atom(instance) and LogLevel.is_level(level) do
    principal_key = principal_key(Keyword.get(opts, :principal))

    with {:ok, message} <- log_message(level, data, opts, nil) do
      Sessions.notify_log_message(instance, level, message, principal_key)
    end
  end

  @doc """
  Sends `notifications/message` to the client of the request that the
  callback runs for.

  `ctx` is the context handed to the callback. The message goes on the
  response stream of the `POST` request (see OzMcp.PostStream), so it
  reaches the client even when no `GET` stream is open. A request that has
  no stream falls back to the `GET` stream of its session.

  For the ctx of a task, the message goes to the owner of the task: each
  attached `tasks/result` stream of the task, else every session of the
  owner (each session applies its own level). The message carries the
  related-task `_meta` (see OzMcp.Tasks.RelatedTask).

  The message is sent only when the level of the session (set by the
  client with `logging/setLevel`) accepts `level`. Before
  `logging/setLevel`, nothing is sent.

  Options: `:logger` (a string).

  Returns `:ok`, also when the level refuses the message or when the
  session drops the message over `max_log_rate`. Returns
  `{:error, :not_encodable}` when `data` holds a term that is not a JSON
  term: nothing is sent.
  """
  @spec log(Context.ctx() | Context.t(), LogLevel.t(), term(), keyword()) ::
          :ok | {:error, :not_encodable}
  def log(ctx_or_server, level, data, opts \\ [])

  def log(%Context{} = context, level, data, opts),
    do: log(Context.to_ctx(context), level, data, opts)

  # The ctx of a task: the task decides where the message goes and each
  # session that receives it applies its own level. The caller checks no
  # level: the level of the session of the request is not the level of the
  # other sessions of the owner.
  #
  def log(%{instance: instance, task_id: task_id}, level, data, opts)
      when is_binary(task_id) and LogLevel.is_level(level) do
    with {:ok, message} <- log_message(level, data, opts, task_id) do
      Tasks.notify(instance, task_id, message, {:log, level})
    end
  end

  def log(%{instance: instance} = ctx, level, data, opts) when LogLevel.is_level(level) do
    session_id = Map.get(ctx, :session_id)

    with {:ok, message} <- log_message(level, data, opts, task_id(ctx)),
         true <- log_wanted?(instance, session_id, level) do
      PostStream.route_log(instance, session_id, Map.get(ctx, :request_id), message)
    else
      false -> :ok
      {:error, :not_encodable} = error -> error
    end
  end

  # The server-wide form of `log/4` was removed: it sent the data of one
  # client to every tenant.
  #
  def log(instance, _level, _data, _opts) when is_atom(instance) and not is_nil(instance) do
    raise ArgumentError,
          "Notify.log/4 takes the ctx of a request, not a server module " <>
            "(#{inspect(instance)}). Use Notify.broadcast_log/4 to send to every " <>
            "session of the server, or Notify.log_session/5 to send to one session"
  end

  @doc """
  Sends `notifications/message` to one session, on its `GET` stream.

  Use it in a process that has no ctx (for example a `GenServer` of the
  application). For a message about a request, use `log/4` with the ctx of
  the request: the message then goes on the stream of the request.

  The message is sent only when the level of the session (set by the
  client with `logging/setLevel`) accepts `level`. Before
  `logging/setLevel`, nothing is sent.

  Options: `:logger` (a string).

  Returns `:ok` (also when the level refuses the message, or when the
  session drops the message over `max_log_rate`),
  `{:error, :no_session}` for an unknown session,
  `{:error, :unavailable}` when the instance does not run, or
  `{:error, :not_encodable}` when `data` holds a term that is not a JSON
  term.
  """
  @spec log_session(module(), String.t(), LogLevel.t(), term(), keyword()) ::
          :ok
          | {:error, :no_session | :unavailable | :not_encodable}
  def log_session(instance, session_id, level, data, opts \\ [])
      when is_atom(instance) and is_binary(session_id) and LogLevel.is_level(level) do
    with {:ok, message} <- log_message(level, data, opts, nil),
         {:ok, delivery} <- session_delivery(instance, session_id) do
      _ =
        if delivery.initialized and LogLevel.wanted?(delivery.log_level, level) do
          _ = Sessions.emit_log(instance, session_id, :session, message)
        end

      :ok
    end
  end

  @spec resource_updated(module(), String.t(), keyword()) ::
          :ok | Sessions.error() | {:error, :invalid_meta | :not_encodable}
  def resource_updated(instance, uri, opts \\ []) do
    meta = Keyword.get(opts, :_meta)

    case Rules.meta_keys(meta) do
      :ok ->
        params =
          if is_nil(meta) do
            %{"uri" => uri}
          else
            Map.put(%{"uri" => uri}, "_meta", meta)
          end

        rpc_notification = JsonRpc.notification("notifications/resources/updated", params)
        Sessions.notify_subscribers(instance, uri, rpc_notification)

      {:error, _message} ->
        {:error, :invalid_meta}
    end
  end

  # Spec: params = NotificationParams & Task (flattened Task fields, no
  # related-task meta).
  #
  # Delivery semantics: session-scoped — delivered to the OWNING session
  # only and to exactly ONE of its registered streams per event (per MCP
  # spec each event is delivered on a single stream, never duplicated
  # across the client's streams). Other sessions never see it.
  #
  # The machinery of a task does not use this sender for its own
  # messages: the status of a task goes to the attached `tasks/result`
  # streams of the task, else to every session of its owner. This
  # sender stays for the code that wants the message on one session.
  #
  @spec task_status(module(), String.t(), Task.t()) ::
          :ok | Sessions.error() | {:error, :not_encodable}
  def task_status(instance, session_id, %Task{} = task),
    do: Sessions.emit(instance, session_id, :session, task_status_message(task))

  # Spec: params = ProgressNotificationParams, with the related-task `_meta`
  # (see OzMcp.Tasks.RelatedTask). Delivery semantics and the note about
  # the machinery of a task: the same as task_status/3 above. Nothing is
  # sent when the token is nil: the task process forwards the record's
  # token, which is absent when the creating request carried no
  # _meta.progressToken.
  #
  # The value is checked per token, for the last 256 tokens of the session:
  # a value that does not increase is dropped.
  #
  @spec task_progress(module(), String.t(), String.t(), term(), number(), number() | nil, term()) ::
          :ok | Sessions.error() | {:error, :not_encodable}
  def task_progress(_server, _session_id, _task_id, nil, _progress, _total, _message), do: :ok

  def task_progress(instance, session_id, task_id, progress_token, progress, total, message)
      when is_binary(task_id) and not is_nil(progress_token) do
    Sessions.emit_progress(
      instance,
      session_id,
      :session,
      progress_token,
      progress,
      task_progress_message(progress_token, progress, total, message, task_id)
    )
  end

  # The builders of the two notifications above. They make the map only:
  # the caller decides where it goes (one session, the sessions of the
  # owner of a task, the streams of a `tasks/result` request).
  #
  @doc false
  @spec task_status_message(Task.t()) :: map()
  def task_status_message(%Task{} = task),
    do: JsonRpc.notification("notifications/tasks/status", Task.build(task))

  @doc false
  @spec task_progress_message(term(), number(), number() | nil, term(), String.t()) :: map()
  def task_progress_message(progress_token, progress, total, message, task_id),
    do: progress_notification(progress_token, progress, total, message, task_id)

  # Spec: params = ProgressNotificationParams (progressToken, progress,
  # optional total/message). No related-task `_meta`: this sender takes
  # no ctx and no task id.
  #
  # Session-wide sender, with the delivery semantics of task_progress/7.
  # It does not know the request: prefer progress/3, which writes on the
  # stream of the request.
  #
  # Safety: tools must only ever pass ctx.progress_token — it is this
  # request's token by construction (extracted generically from the request
  # _meta). progress/5 is public and does not verify ownership.
  #
  # The value is checked per token, for the last 256 tokens of the session:
  # a value that does not increase is dropped.
  #
  @spec progress(module(), String.t(), term(), number(), keyword()) ::
          :ok | {:error, :unavailable}
  def progress(instance, session_id, token, progress, opts \\ []) do
    session_progress(instance, session_id, token, progress, opts[:total], opts[:message])
  end

  @doc """
  Reports the progress of the request the callback runs for.

  `ctx` is the context handed to the callback. The notification carries the
  `progressToken` of the request (nothing is sent when the request had
  none) and is written on the response stream of that `POST` request, so it
  reaches the client even when no `GET` stream is open (see
  OzMcp.PostStream). The response becomes an event stream, as for a
  request to the client. A request that has no stream (a process of the
  application) falls back to the `GET` stream of the session, like
  `progress/5`.

  When the ctx belongs to a task (`ctx.task_id` is set), this call and
  `OzMcp.Tasks.Context.progress/4` are the same: both call
  OzMcp.Tasks.progress/5, which checks the values before the send. The
  task sends the notification to the owner of the task like the log and
  it carries the `io.modelcontextprotocol/related-task` `_meta`; the raw
  `progress/5` takes no ctx and never adds it.

  Options: `:total` and `:message`.

  The `progress` value must increase with each call for the same token.
  A value that is equal to or smaller than the last one is dropped: the
  function returns `:ok` and the client gets nothing. A debug line is
  written. The first value can be any number. A value that is not a
  number is not checked.

  Progress is only meaningful while the request runs: do not call it after
  the callback returned.

  Returns `{:error, :not_encodable}` when a value holds a term that
  JSON cannot encode (for example a pid in the `:message` option): nothing
  is sent and the request goes on. For the ctx of a task it can also give
  `{:error, :unavailable}` when the instance does not run.
  """
  @spec progress(Context.ctx() | Context.t(), number(), keyword()) ::
          :ok | {:error, :not_encodable | :unavailable}
  def progress(ctx, progress, opts \\ [])

  def progress(%Context{} = context, progress, opts),
    do: progress(Context.to_ctx(context), progress, opts)

  def progress(%{progress_token: nil}, _progress, _opts), do: :ok

  # The clause of a nil token comes first: these two clauses see only a
  # token that is not nil. A ctx with a token and no `:instance` cannot
  # send the notification; losing it with no error would hide the defect.
  #
  def progress(%{progress_token: _token, instance: nil}, _progress, _opts),
    do: raise_no_instance!()

  def progress(%{progress_token: _token} = ctx, _progress, _opts)
      when not is_map_key(ctx, :instance),
      do: raise_no_instance!()

  # The ctx of a task: the check of the values and the send are the same
  # as `OzMcp.Tasks.Context.progress/4` (both call `Tasks.progress/5`).
  #
  def progress(%{task_id: task_id, instance: instance, progress_token: token}, progress, opts)
      when is_binary(task_id) and not is_nil(token),
      do: Tasks.progress(instance, task_id, progress, opts[:total], opts[:message])

  def progress(%{progress_token: token, instance: instance} = ctx, progress, opts)
      when not is_nil(token) do
    message = progress_notification(token, progress, opts[:total], opts[:message], task_id(ctx))

    PostStream.route_progress(
      instance,
      Map.get(ctx, :session_id),
      Map.get(ctx, :request_id),
      token,
      progress,
      message
    )
  end

  def progress(_ctx, _progress, _opts), do: :ok

  defp raise_no_instance! do
    raise ArgumentError,
          "Notify.progress/3 takes a ctx with :instance (the ctx that the library " <>
            "gives to a callback has it)"
  end

  defp session_progress(_server, _session_id, nil, _progress, _total, _message), do: :ok

  defp session_progress(instance, session_id, token, progress, total, message) do
    rpc_notification = progress_notification(token, progress, total, message)
    Sessions.emit_progress(instance, session_id, :session, token, progress, rpc_notification)
  end

  @doc """
  Tells the client that an elicitation in URL mode is done (the user finished
  the interaction on the web page).

  `elicitation_id` is the id of `OzMcp.Client.elicit/3` (it is part of its
  result). The notification goes out only if the client declared the `url`
  mode of `elicitation`; otherwise `{:error, :capability_not_supported}`
  is returned and nothing is sent. Returns `{:error, :no_session}` for
  an unknown session.

  The notification is delivered on the `GET` stream of the session. A
  client ignores an id it does not know.

  The `task_id` is the id of the task that asked the elicitation (the
  `task_id` of its ctx, or `nil`). The notification then carries the
  related-task `_meta`. For a task that runs, the capability check reads
  the capabilities that the request which created the task declared and
  the notification goes to the owner of the task (each attached
  `tasks/result` stream, else every session of the owner). A task that
  does not run keeps the session of the caller.
  """
  @spec elicitation_complete(module(), String.t(), String.t(), String.t() | nil) ::
          :ok | {:error, :capability_not_supported | :no_session}
  def elicitation_complete(instance, session_id, elicitation_id, task_id \\ nil)
      when is_binary(session_id) and is_binary(elicitation_id) and elicitation_id != "" do
    with {:ok, capabilities, task?} <- capabilities_for(instance, session_id, task_id) do
      if Context.capability?(capabilities, [:elicitation, :url]) do
        message =
          JsonRpc.notification(
            "notifications/elicitation/complete",
            RelatedTask.put(%{"elicitationId" => elicitation_id}, task_id)
          )

        _ =
          if task?,
            do: Tasks.notify(instance, task_id, message),
            else: Sessions.emit(instance, session_id, :session, message)

        :ok
      else
        {:error, :capability_not_supported}
      end
    end
  end

  # The capabilities of the client that receives the notification and
  # where it goes: `{:task, true}` sends through the task, `{:task,
  # false}` keeps the GET stream of the session (a task that does not run,
  # as today). Each failure of the session gives `{:error, :no_session}`.
  #
  defp capabilities_for(instance, session_id, nil), do: session_capabilities(instance, session_id)

  defp capabilities_for(instance, session_id, task_id) do
    case Tasks.client_capabilities(instance, task_id) do
      {:ok, capabilities} ->
        {:ok, capabilities, true}

      _no_task ->
        session_capabilities(instance, session_id)
    end
  end

  defp session_capabilities(instance, session_id) do
    case Sessions.client_capabilities(instance, session_id) do
      {:ok, capabilities} -> {:ok, capabilities, false}
      _unknown_session -> {:error, :no_session}
    end
  end

  defp progress_notification(token, progress, total, message, task_id \\ nil) do
    params =
      %{progress: progress, progressToken: token}
      |> maybe_total(total)
      |> maybe_message(message)
      |> RelatedTask.put(task_id, :_meta)

    JsonRpc.notification("notifications/progress", params)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp principal_key(nil), do: nil
  defp principal_key(%Principal{} = principal), do: Principal.key(principal)

  defp principal_key({issuer, subject} = key)
       when (is_binary(issuer) or is_nil(issuer)) and is_binary(subject) and subject != "",
       do: key

  defp principal_key(other),
    do: raise(ArgumentError, "invalid :principal option: #{inspect(other)}")

  # The params of notifications/message. The related-task _meta is added
  # for the ctx of a task. The params are checked here, before the send: a
  # term that JSON cannot encode can stop the process that writes the
  # stream (the request process for a POST stream).
  #
  defp log_message(level, data, opts, task_id) do
    params =
      %{"level" => Atom.to_string(level), "data" => data}
      |> maybe_put("logger", opts[:logger])
      |> maybe_related_task(task_id)

    case Wire.check(params) do
      :ok ->
        {:ok, JsonRpc.notification("notifications/message", params)}

      {:error, path, _reason} ->
        #
        # The path only: the data can hold client information.
        #
        Logger.error(
          "notifications/message is not JSON-encodable at " <>
            "#{Wire.format_path(path)}, not sent"
        )

        {:error, :not_encodable}
    end
  end

  defp maybe_related_task(params, nil), do: params

  defp maybe_related_task(params, task_id),
    do: RelatedTask.put(params, task_id)

  defp task_id(%{task_id: task_id}) when is_binary(task_id), do: task_id
  defp task_id(_ctx), do: nil

  # The level filter of the scoped forms. It runs in the caller: a message
  # on the stream of a POST request does not go through the session.
  #
  defp log_wanted?(instance, session_id, level) when is_binary(session_id) do
    case Sessions.delivery(instance, session_id) do
      {:ok, %{initialized: true, log_level: session_level}} ->
        LogLevel.wanted?(session_level, level)

      _ ->
        false
    end
  end

  defp log_wanted?(_instance, _session_id, _level), do: false

  # The read of a session for the session form of the log: an unknown
  # session is an error for the caller (it names the session itself),
  # unlike the ctx form where it only means "send nothing".
  #
  defp session_delivery(instance, session_id), do: Sessions.delivery(instance, session_id)

  defp maybe_total(params, nil), do: params
  defp maybe_total(params, total), do: Map.put(params, :total, total)

  defp maybe_message(params, nil), do: params
  defp maybe_message(params, message), do: Map.put(params, :message, message)
end
