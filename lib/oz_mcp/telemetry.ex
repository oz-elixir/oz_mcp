#
# The telemetry handle of one instance. The boot builds it once
# (`new/3`) and keeps it in `%OzMcp.Instance.Config{}`. A process that
# emits keeps the handle in its state. The handle holds the full event
# names, so an emit never builds a name.
#
defmodule OzMcp.Telemetry do
  @moduledoc false

  @spans [:request, :callback, :session, :task, :client_request, :client_task]

  @points %{
    auth_refused: [:auth, :refused],
    limit_reached: [:limit, :reached],
    log_dropped: [:log, :dropped],
    session_restore: [:session, :restore],
    snapshot_write: [:snapshot, :write],
    principal_revoked: [:principal, :revoked],
    subscription_dropped: [:subscription, :dropped]
  }

  @enforce_keys [:instance, :server, :spans, :points]
  defstruct [:instance, :server, :spans, :points]

  @type t :: %__MODULE__{}

  @type span :: :request | :callback | :session | :task | :client_request | :client_task

  @opaque token :: {t(), span(), integer(), reference(), map()}

  @spec new(atom(), module(), [atom()]) :: t()
  def new(instance, server, prefix) do
    spans =
      Map.new(@spans, fn key ->
        {key,
         %{
           start: prefix ++ [key, :start],
           stop: prefix ++ [key, :stop],
           exception: prefix ++ [key, :exception]
         }}
      end)

    points = Map.new(@points, fn {key, tail} -> {key, prefix ++ tail} end)

    %__MODULE__{instance: instance, server: server, spans: spans, points: points}
  end

  # The handle of a running instance, or `nil` when the instance does not run.
  # It reads the config: use it only where no config read is already done
  # and only on a path that is not hot (a refusal, a request to the client).
  #
  @spec handle(OzMcp.Instance.t()) :: t() | nil
  def handle(instance) do
    case OzMcp.Instance.config(instance) do
      {:ok, %{telemetry: %__MODULE__{} = telemetry}} -> telemetry
      _other -> nil
    end
  end

  # Start a span. Gives a token for `stop/2`.
  #
  @spec start(t() | nil, span(), map(), atom() | nil) :: token() | nil
  def start(handle, key, meta \\ %{}, transport \\ nil)
  def start(nil, _key, _meta, _transport), do: nil

  def start(%__MODULE__{} = t, key, meta, transport) do
    meta = base(t, transport, meta)
    ref = make_ref()
    now = System.monotonic_time()

    :telemetry.execute(
      t.spans[key].start,
      %{system_time: System.system_time(), monotonic_time: now},
      Map.put(meta, :telemetry_span_context, ref)
    )

    {t, key, now, ref, meta}
  end

  # End a span. The extra metadata is merged into the metadata of the start.
  #
  @spec stop(token() | nil, map()) :: :ok
  def stop(nil, _extra), do: :ok

  def stop({t, key, started, ref, meta}, extra) do
    :telemetry.execute(
      t.spans[key].stop,
      %{duration: System.monotonic_time() - started},
      meta |> Map.merge(extra) |> Map.put(:telemetry_span_context, ref)
    )
  end

  # End a span with an exception.
  #
  @spec exception(token() | nil, atom(), term(), list()) :: :ok
  def exception(nil, _kind, _reason, _stacktrace), do: :ok

  def exception({t, key, started, ref, meta}, kind, reason, stacktrace) do
    :telemetry.execute(
      t.spans[key].exception,
      %{duration: System.monotonic_time() - started},
      Map.merge(meta, %{
        exception_kind: kind,
        reason: reason,
        stacktrace: stacktrace,
        telemetry_span_context: ref
      })
    )
  end

  # Run `fun` inside a span. `fun` gives `{result, extra_meta}`. An exception
  # ends the span with `exception/4` and goes on.
  #
  @spec span(t() | nil, span(), map(), atom() | nil, (-> {term(), map()})) :: term()
  def span(handle, key, meta, transport, fun) do
    token = start(handle, key, meta, transport)

    try do
      {result, extra} = fun.()
      stop(token, extra)
      result
    catch
      kind, reason ->
        exception(token, kind, reason, __STACKTRACE__)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  # Emit the `:stop` event of a span that has no token (a process that
  # cannot emit its own `:stop`). The event has no span context.
  #
  @spec stop_untracked(t() | nil, span(), integer(), map()) :: :ok
  def stop_untracked(nil, _key, _duration, _meta), do: :ok

  def stop_untracked(%__MODULE__{} = t, key, duration, meta),
    do: :telemetry.execute(t.spans[key].stop, %{duration: duration}, base(t, nil, meta))

  # Emit a point event.
  #
  @spec event(t() | nil, atom(), map(), map()) :: :ok
  def event(nil, _key, _measurements, _meta), do: :ok

  def event(%__MODULE__{} = t, key, measurements, meta),
    do: :telemetry.execute(Map.fetch!(t.points, key), measurements, base(t, nil, meta))

  # Emit the event of a limit that the server reached, with the name of the
  # limit, the value of the option that set it, the scope that the limit
  # counts and the outcome. The outcome is `:refused` when the server refused
  # the work and `:replaced` when the server ended the oldest stream to make
  # room. No id of a session or of a principal goes out.
  #
  @spec limit(
          t() | nil,
          atom(),
          pos_integer(),
          :instance | :principal | :session,
          :refused | :replaced
        ) :: :ok
  def limit(handle, limit, value, scope, outcome \\ :refused) do
    event(handle, :limit_reached, %{count: 1}, %{
      limit: limit,
      limit_value: value,
      scope: scope,
      outcome: outcome
    })
  end

  # A `nil` transport adds no key: only the events that know the transport
  # carry the key.
  #
  defp base(t, nil, meta), do: Map.merge(meta, %{instance: t.instance, server: t.server})

  defp base(t, transport, meta),
    do: Map.merge(meta, %{instance: t.instance, server: t.server, transport: transport})
end
