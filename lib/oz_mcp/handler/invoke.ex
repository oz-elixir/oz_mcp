#
# Runs a user callback (`tool.call/2`, `resource.read/2`, `prompt.get/2`,
# `completion.complete/4`) in its own supervised process, behind a crash
# guard, a deadline and a cancel.
#
# The callers are `run/3` (the caller waits) and `start/2` (detached, used
# by tasks). The rules of the deadline, the cancel and the JSON terms are
# in the guide "Tools", section "The callback".
#
# The callback does not run in the process of the request: `self()` and
# the process dictionary of the request are not visible to it.
#
defmodule OzMcp.Handler.Invoke do
  @moduledoc false

  alias OzMcp.Config.DSL.Rules
  alias OzMcp.Context
  alias OzMcp.Handler.{Output, Result}
  alias OzMcp.Instance
  alias OzMcp.Session
  alias OzMcp.Stream
  alias OzMcp.Structs.{CallToolResult, CompleteResult, GetPromptResult, ReadResourceResult}
  alias OzMcp.Telemetry
  alias OzMcp.Utils.Error
  alias OzMcp.Wire

  require Logger

  @internal_code -32603
  @internal_message "internal error"

  @reserved_codes [-32800, -32600]

  @shaped_methods Result.methods()
  @timeout_message "request execution timed out"

  # The timeout error shares its code with real crashes: the data member is
  # the one way for a client to tell a deadline overrun apart.
  #
  @timeout_data %{"reason" => "timeout"}

  @cancelled_code -32800
  @cancelled_message "request cancelled"

  # The documented server errors use -32000; every internal error of the
  # framework uses the standard -32603.
  #
  @session_code -32000
  @session_message "session terminated"

  @cancel_tag :oz_mcp_cancel

  @max_reason_bytes 200

  @type callback_result :: {:ok, term()} | {:error, Error.t() | map()}
  @type ctx :: Context.t() | Context.ctx()

  # Runs the callback and waits for its result. The ctx holds `:instance`
  # and the deadline is the `request_timeout_ms` option of that instance.
  #
  # Options: `:timeout` (milliseconds or `:infinity`), `:isolation`
  # (`:inline` runs in the caller process, for unit tests only),
  # `:keep_alive`, `:session_end_error`, `:stream` (then the result is
  # `{outcome, stream}`) and `:telemetry_name` (the name in the metadata of
  # the `callback` span).
  #
  @spec run(ctx(), (-> term())) :: callback_result()
  def run(ctx, fun), do: run(ctx, fun, [])

  @spec run(ctx(), (-> term()), keyword()) ::
          callback_result() | {callback_result(), Stream.t() | nil}
  def run(ctx, fun, opts) when is_function(fun, 0) and is_list(opts) do
    has_stream? = Keyword.has_key?(opts, :stream)
    stream = Keyword.get(opts, :stream)
    instance = ctx_instance(ctx)
    supervisor = supervisor(instance, opts)
    {exec_opts, telemetry} = settings(ctx, supervisor)
    deadline = deadline(exec_opts, opts)

    method = ctx_method(ctx)
    check = Keyword.get(opts, :check)
    guard = fn -> guarded(fun, method, check, exec_opts.check_results) end
    meta = %{method: method, name: Keyword.get(opts, :telemetry_name)}

    body = fn ->
      result =
        case supervisor do
          nil ->
            {guard.(), stream}

          :not_running ->
            {refused(instance), stream}

          supervisor ->
            run_supervised(supervisor, ctx, guard, deadline, exec_opts, opts, stream)
        end

      {finish(result, has_stream?), outcome_meta(elem(result, 0))}
    end

    Telemetry.span(telemetry, :callback, meta, nil, body)
  end

  defp finish({outcome, _stream}, false), do: outcome
  defp finish({outcome, stream}, true), do: {outcome, stream}

  defp outcome_meta({:ok, _result}), do: %{result: :ok, error_code: nil}

  defp outcome_meta({:error, %{code: @cancelled_code}}),
    do: %{result: :cancelled, error_code: @cancelled_code}

  defp outcome_meta({:error, %{code: @internal_code, data: @timeout_data}}),
    do: %{result: :timeout, error_code: @internal_code}

  defp outcome_meta({:error, %{code: @internal_code}}),
    do: %{result: :crashed, error_code: @internal_code}

  defp outcome_meta({:error, %{code: @session_code, message: @session_message}}),
    do: %{result: :session_terminated, error_code: @session_code}

  defp outcome_meta({:error, %{code: code}}), do: %{result: :error, error_code: code}

  # Starts the callback in a detached process and returns its pid. A
  # detached callback belongs to no request: `notifications/cancelled`
  # never stops it.
  #
  # Options: `:supervisor` (required), `:on_exit` (called with the result),
  # `:method`, `:check` and `:check_results`.
  #
  @spec start((-> term()), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(fun, opts) when is_function(fun, 0) and is_list(opts) do
    supervisor = Keyword.fetch!(opts, :supervisor)
    on_exit = Keyword.get(opts, :on_exit, fn _result -> :ok end)
    method = Keyword.get(opts, :method)
    check = Keyword.get(opts, :check)
    check_results = Keyword.get(opts, :check_results, true)

    Task.Supervisor.start_child(supervisor, fn ->
      on_exit.(guarded(fun, method, check, check_results))
    end)
  end

  # The worker of one streaming request, or a refusal during a restart
  # window.
  #
  @doc false
  @spec start_worker(instance :: module(), fun :: (-> term())) ::
          {:ok, pid()} | {:error, term()}
  def start_worker(instance, fun) when is_function(fun, 0) do
    case Instance.whereis(instance, :calls) do
      {:ok, supervisor} ->
        Task.Supervisor.start_child(supervisor, fun)

      :not_running ->
        if running?(instance), do: {:error, :unavailable}, else: {:ok, spawn(fun)}
    end
  end

  defp deadline(exec_opts, opts) do
    case Keyword.get(opts, :timeout) || exec_opts.request_timeout_ms do
      deadline when deadline in [nil, :infinity] ->
        :infinity

      ms when is_integer(ms) and ms > 0 ->
        ms

      other ->
        raise ArgumentError,
              "timeout must be a positive integer (ms), :infinity or nil, got: #{inspect(other)}"
    end
  end

  # nil runs inline (no deadline, no cancellation); `:not_running` must
  # not run in the caller process.
  #
  defp supervisor(instance, opts) do
    if Keyword.get(opts, :isolation) == :inline do
      warn_inline(instance)
      nil
    else
      case Instance.whereis(instance, :calls) do
        {:ok, name} ->
          name

        :not_running ->
          if running?(instance), do: :not_running, else: nil
      end
    end
  end

  defp running?(instance), do: match?({:ok, _config}, Instance.config(instance))

  # A callback with no deadline and no cancellation is not acceptable.
  #
  defp refused(instance) do
    Logger.warning(
      "the invoke supervisor of #{inspect(instance)} is not running: the callback is not started"
    )

    internal_error()
  end

  defp warn_inline(instance) do
    case Instance.whereis(instance, :calls) do
      {:ok, _name} ->
        Logger.warning(
          "isolation: :inline runs the callback of #{inspect(instance)} in the caller " <>
            "process, without deadline and without cancellation"
        )

      :not_running ->
        :ok
    end
  end

  defp settings(%Context{config: %OzMcp.Instance.Config{} = config}, _supervisor),
    do: {config.opts, config.telemetry}

  defp settings(ctx, supervisor) do
    instance = ctx_instance(ctx)

    case OzMcp.Instance.config(instance) do
      {:ok, config} ->
        {config.opts, config.telemetry}

      :not_running ->
        if supervisor do
          Logger.warning(
            "execution options of #{inspect(instance)} are not available: " <>
              "using the defaults (no deadline)"
          )
        end

        {OzMcp.Instance.opts(instance), nil}
    end
  end

  defp ctx_instance(%{instance: instance}), do: instance

  defp ctx_method(%Context{rpc_method: method}), do: method
  defp ctx_method(_ctx), do: nil

  defp ctx_session_id(%Context{session_id: session_id}), do: session_id
  defp ctx_session_id(ctx), do: Map.get(ctx, :session_id)

  defp ctx_request_id(%Context{rpc_id: request_id}), do: request_id
  defp ctx_request_id(ctx), do: Map.get(ctx, :request_id)

  defp registered?(ctx) do
    session_id = ctx_session_id(ctx)
    request_id = ctx_request_id(ctx)

    is_binary(session_id) and (is_binary(request_id) or is_integer(request_id))
  end

  # `{:error, :no_request}`: the caller died before this call, so nobody
  # waits for the result and the callback does not start. Any other error
  # is best effort.
  #
  defp attach_runner(nil, _caller), do: :ok

  defp attach_runner({instance, session_id, request_id}, caller) do
    with {:error, :no_request} <- Session.attach_runner(instance, session_id, request_id, self()),
         false <- Process.alive?(caller) do
      exit(:shutdown)
    else
      _ -> :ok
    end
  end

  defp run_supervised(supervisor, ctx, fun, deadline, exec_opts, opts, stream) do
    grace = exec_opts.request_cancel_grace_ms

    # A caller runs one request at a time: a cancel in its mailbox
    # targets a request that ended (flush_stale/1). A cancel for THIS
    # request can already be here and is kept.
    #
    flush_stale(ctx_request_id(ctx))

    # async_nolink: a crashing callback is reported as a -32603 result and
    # never tears down the caller.
    #
    # The callback process names itself to the session (attach_runner/2).
    # The caller must not: a caller that dies between the spawn and the
    # call would leave a callback that nobody can stop. The closure holds
    # three small values, not the ctx.
    #
    caller = self()

    request =
      if registered?(ctx),
        do: {ctx_instance(ctx), ctx_session_id(ctx), ctx_request_id(ctx)}

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        attach_runner(request, caller)
        fun.()
      end)

    wait = %{
      grace: grace,
      instance: ctx_instance(ctx),
      session_id: ctx_session_id(ctx),
      request_id: ctx_request_id(ctx),
      heartbeat: exec_opts.sse_heartbeat_ms,
      keep_alive: Keyword.get(opts, :keep_alive, false),
      session_end_error: Keyword.get(opts, :session_end_error, false)
    }

    await(task, deadline, wait, stream)
  end

  defp await(task, deadline, wait, stream) do
    until =
      if deadline == :infinity,
        do: :infinity,
        else: System.monotonic_time(:millisecond) + deadline

    await(task, deadline, until, wait, stream)
  end

  defp await(%Task{ref: ref, pid: pid} = task, deadline, until, wait, stream) do
    %{
      grace: grace,
      instance: instance,
      session_id: session_id,
      request_id: request_id,
      heartbeat: heartbeat
    } =
      wait

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        flush_cancel(request_id)
        {result, stream}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flush_cancel(request_id)
        log_down(reason)
        {internal_error(), stream}

      {@cancel_tag, ^request_id, reason} ->
        {reason, error} = cancel_error(reason, wait.session_end_error)
        Logger.debug("request cancelled#{format_reason(reason)}")
        _ = Session.abandon_waiter(instance, session_id, pid, "the request was cancelled")

        result =
          case stop(task, {:shutdown, {:cancelled, reason}}, grace, request_id) do
            {:finished, result} -> result
            :stopped -> {:error, error}
          end

        {result, stream}

      {:oz_mcp_stream, stream_id, _payload} = message
      when not is_nil(stream) and stream_id == stream.stream_id ->
        stream = stream_of(stream, message)
        await(task, deadline, until, wait, stream)

      {:oz_mcp_stream, _stream_id, :taken_over} ->
        await(task, deadline, until, wait, stream)
    after
      wake_in(until, heartbeat) ->
        if remaining(until) > 0 do
          await(task, deadline, until, wait, heartbeat_of(stream, wait))
        else
          Logger.error("user callback exceeded the #{deadline} ms deadline and was stopped")
          _ = Session.abandon_waiter(instance, session_id, pid, "the request timed out")

          result =
            case stop(task, :shutdown, grace, request_id) do
              {:finished, result} ->
                result

              :stopped ->
                {:error, Error.new(@internal_code, @timeout_message, @timeout_data)}
            end

          {result, stream}
        end
    end
  end

  defp stream_of(%{__struct__: module} = stream, message), do: module.relay(stream, message)

  defp heartbeat_of(nil, _wait), do: nil

  defp heartbeat_of(%{__struct__: module} = stream, wait),
    do: module.heartbeat(stream, start: wait.keep_alive)

  defp wake_in(until, heartbeat) do
    case {remaining(until), heartbeat} do
      {:infinity, heartbeat} -> heartbeat
      {left, :infinity} -> left
      {left, heartbeat} -> min(left, heartbeat)
    end
  end

  defp remaining(:infinity), do: :infinity
  defp remaining(until), do: max(until - System.monotonic_time(:millisecond), 0)

  # Two steps: a trapable exit signal, then a kill when the grace elapses.
  # A result that arrives in the meantime wins.
  #
  defp stop(%Task{ref: ref, pid: pid}, signal, grace, request_id) do
    Process.exit(pid, signal)

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        flush_cancel(request_id)
        {:finished, result}

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        flush_cancel(request_id)
        :stopped
    after
      grace ->
        Process.exit(pid, :kill)

        receive do
          {^ref, result} ->
            Process.demonitor(ref, [:flush])
            flush_cancel(request_id)
            {:finished, result}

          {:DOWN, ^ref, :process, ^pid, _reason} ->
            flush_cancel(request_id)
            :stopped
        end
    end
  end

  # A cancel can arrive after the wait ended: drop it, the mailbox of the
  # caller (a long lived connection process) must not collect it. A cancel
  # that races with the end of the wait is dropped by flush_stale/1 when
  # the caller starts its next request.
  #
  @doc false
  def flush_cancel(request_id) do
    receive do
      {@cancel_tag, ^request_id, _reason} -> flush_cancel(request_id)
    after
      0 -> :ok
    end
  end

  @doc false
  def flush_stale(request_id) do
    receive do
      {@cancel_tag, other_id, _reason} when other_id != request_id -> flush_stale(request_id)
    after
      0 -> :ok
    end
  end

  defp cancel_error(:session_terminated, true),
    do: {"session terminated", Error.new(@session_code, @session_message)}

  defp cancel_error(:session_terminated, false),
    do: {"session terminated", Error.new(@cancelled_code, @cancelled_message)}

  defp cancel_error(reason, _session_end_error),
    do: {reason, Error.new(@cancelled_code, @cancelled_message)}

  # `inspect` escapes control characters (no log line injection).
  #
  defp format_reason(reason) when is_binary(reason),
    do: " (reason: #{inspect(reason, printable_limit: @max_reason_bytes)})"

  defp format_reason(_reason), do: ""

  # The guard runs the callback and turns every way it can fail (a raise,
  # a throw, an exit, an unexpected result) into the generic internal
  # error, so no detail of a failure reaches the wire.
  #
  defp guarded(fun, method, check, check_results) do
    fun.() |> normalize(method, check_results) |> check_result(check)
  rescue
    error ->
      log_crash(:error, error, __STACKTRACE__)
      internal_error()
  catch
    kind, value ->
      log_crash(kind, value, __STACKTRACE__)
      internal_error()
  end

  defp check_result({:ok, value} = ok, check) when is_function(check, 1) do
    case check.(value) do
      :ok -> ok
      {:error, messages} -> {:error, Output.error(messages)}
    end
  end

  defp check_result(result, _check), do: result

  defp normalize({:error, %Error{code: code} = error}, _method, _check_results)
       when is_integer(code) do
    check_error(error, code, error.data)
  end

  defp normalize({:error, %{code: code, message: message} = error}, _method, _check_results)
       when is_integer(code) and is_binary(message) do
    #
    # Plain-map error (house style for already-built errors): make sure
    # the data key always exists, the caller reads it unconditionally.
    #
    data = Map.get(error, :data)
    check_error(%{code: code, message: message, data: data}, code, data)
  end

  defp normalize({:ok, %CallToolResult{} = result}, _method, true),
    do: build(CallToolResult, result)

  defp normalize({:ok, %ReadResourceResult{} = result}, _method, true),
    do: build(ReadResourceResult, result)

  defp normalize({:ok, %GetPromptResult{} = result}, _method, true),
    do: build(GetPromptResult, result)

  defp normalize({:ok, %CompleteResult{} = result}, _method, true),
    do: build(CompleteResult, result)

  # A wire-ready map result of a shaped method is built into its result
  # struct, so a map and a struct get the same check.
  #
  defp normalize({:ok, value}, method, true)
       when is_map(value) and not is_struct(value) and method in @shaped_methods do
    case Result.normalize(method, value) do
      {:ok, built} -> check_json(built)
      {:error, reason} -> log_bad_shape(method, reason)
    end
  end

  defp normalize({:ok, value}, _method, true)
       when is_map(value) and not is_struct(value) do
    with :ok <- check_meta(value) do
      check_json(value)
    end
  end

  defp normalize({:ok, _value}, method, true) when method in @shaped_methods do
    log_bad_shape(method, "the result must be an object")
  end

  defp normalize({:ok, value}, _method, true), do: check_json(value)

  defp normalize({:ok, %CallToolResult{} = result}, _method, false),
    do: {:ok, CallToolResult.build(result)}

  defp normalize({:ok, %ReadResourceResult{} = result}, _method, false),
    do: {:ok, ReadResourceResult.build(result)}

  defp normalize({:ok, %GetPromptResult{} = result}, _method, false),
    do: {:ok, GetPromptResult.build(result)}

  defp normalize({:ok, %CompleteResult{} = result}, _method, false),
    do: {:ok, CompleteResult.build(result)}

  defp normalize({:ok, value}, _method, false), do: {:ok, value}

  defp normalize(other, _method, _check_results) do
    log_crash(:exit, {:invalid_callback_result, other}, nil)
    internal_error()
  end

  @doc false
  def normalize_unchecked(value, method), do: normalize({:ok, value}, method, false)

  defp check_error(_error, code, _data) when code in @reserved_codes do
    Logger.warning("a callback returned the reserved error code #{code}")
    internal_error()
  end

  defp check_error(error, _code, data) do
    case Wire.check(%{message: error.message, data: data}) do
      :ok ->
        {:error, error}

      {:error, path, reason} ->
        Logger.warning(
          "a callback returned an error that is not JSON, " <>
            "at #{Wire.format_path(path)}: #{Wire.describe(reason)}"
        )

        internal_error()
    end
  end

  defp check_json(value) do
    case Wire.check(value) do
      :ok -> {:ok, value}
      {:error, path, reason} -> reject(path, reason)
    end
  end

  defp log_bad_shape(method, reason) do
    Logger.error("user callback returned a bad result for #{method}: #{reason}")
    internal_error()
  end

  # A `_meta` under a nested map is not checked. The message names the
  # key with `inspect/1`: the key comes from the server code.
  #
  defp check_meta(value) do
    with :ok <- Rules.meta_keys(Map.get(value, "_meta")),
         :ok <- Rules.meta_keys(Map.get(value, :_meta)) do
      :ok
    else
      {:error, message} ->
        Logger.warning("a callback returned a bad _meta: #{message}")
        internal_error()
    end
  end

  # A struct that fails its own build validation is a server bug.
  #
  defp build(module, result) do
    built = module.build(result)

    case Wire.check(built) do
      :ok -> {:ok, built}
      {:error, path, reason} -> reject(path, reason)
    end
  rescue
    error ->
      log_crash(:error, error, __STACKTRACE__)
      internal_error()
  end

  # Last gate before the wire (`OzMcp.Wire.check/1`).
  #
  defp reject(path, reason) do
    Logger.error(
      "user callback returned a value that cannot be encoded as JSON, " <>
        "at #{Wire.format_path(path)}: #{Wire.describe(reason)}"
    )

    internal_error()
  end

  # A `:shutdown` is a stop from outside: the callback did not fail, so
  # it is no crash.
  #
  defp log_down(reason) when reason == :shutdown,
    do: Logger.debug("user callback stopped: shutdown")

  defp log_down({:shutdown, _} = reason),
    do: Logger.debug("user callback stopped: #{inspect(reason)}")

  defp log_down(reason), do: log_crash(:exit, reason, nil)

  defp log_crash(kind, reason, stacktrace) do
    Logger.error("user callback crashed: " <> Exception.format(kind, reason, stacktrace))
  end

  defp internal_error, do: {:error, Error.new(@internal_code, @internal_message)}
end
