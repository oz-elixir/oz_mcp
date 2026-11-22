#
# One function per stage of the HTTP pipelines of the router:
# `OzMcp.Validate` delegates to it. A stage answers `{:cont, context}` or
# `{:halt, context}`.
#
# `restore/1` is the only stage that can start a session; the stages
# that read the session never start one.
#
defmodule OzMcp.Validate.Http do
  @moduledoc false

  import Plug.Conn

  alias OzMcp.Transport.Http.Accept

  alias OzMcp.Auth.{Challenge, Gate, Guard, Principal, Scopes}
  alias OzMcp.{Context, Pipeline, Protocol, Sessions, Telemetry}
  alias OzMcp.Pipeline.Bound

  require Logger

  @no_session_methods [
    "initialize"
  ]

  @spec auth(Context.t()) :: Pipeline.result()
  def auth(%{conn: nil} = context), do: {:cont, context}

  def auth(context) do
    case context.conn.private[:oz_mcp_principal] do
      nil -> {:cont, context}
      principal -> {:cont, Map.put(context, :principal, principal)}
    end
  end

  # A POST needs both media types with a quality above zero. Every
  # `Accept` header is read: the first header alone does not decide.
  #
  @spec headers(Context.t()) :: Pipeline.result()
  def headers(context) do
    ranges = Accept.ranges(context.conn)

    cond do
      no_accept_header?(context.conn) ->
        Pipeline.halt(context, :http_no_accept_header)

      Accept.accepts?(ranges, "application/json") and
          Accept.accepts?(ranges, "text/event-stream") ->
        {:cont, context}

      true ->
        Pipeline.halt(context, :http_bad_accept_header)
    end
  end

  @spec sse_header(Context.t()) :: Pipeline.result()
  def sse_header(context) do
    ranges = Accept.ranges(context.conn)

    cond do
      no_accept_header?(context.conn) ->
        Pipeline.halt(context, :http_no_accept_header)

      Accept.accepts?(ranges, "text/event-stream") ->
        {:cont, context}

      true ->
        Pipeline.halt(context, :http_no_event_stream_accept_header)
    end
  end

  defp no_accept_header?(conn), do: get_req_header(conn, "accept") == []

  # Two header lines are a defect, also when the values are equal; the
  # stage runs before the compare with the version of the session.
  #
  @spec protocol_version(Context.t()) :: Pipeline.result()
  def protocol_version(%{rpc_method: "initialize"} = context), do: {:cont, context}

  def protocol_version(context) do
    case get_req_header(context.conn, "mcp-protocol-version") do
      [] ->
        {:cont, context}

      [version] ->
        if Protocol.supported?(version),
          do: {:cont, context},
          else: Pipeline.halt(context, :http_unsupported_protocol_version)

      [_first, _second | _rest] ->
        Pipeline.halt(context, :http_unsupported_protocol_version)
    end
  end

  # The stage reads the header only; a value that is not a valid session
  # id is refused before the lookup.
  #
  @max_session_id_bytes 128

  @spec session_id(Context.t()) :: Pipeline.result()
  def session_id(%{rpc_method: "initialize"} = context) do
    case get_session_id(context.conn) do
      :none -> {:cont, context}
      _header -> Pipeline.halt(context, :http_initialize_with_session_id)
    end
  end

  def session_id(context) do
    case get_session_id(context.conn) do
      {:ok, id} -> {:cont, Map.put(context, :session_id, id)}
      :none -> Pipeline.halt(context, :http_missing_session_id)
      :invalid -> Pipeline.halt(context, :http_invalid_session_id)
    end
  end

  defp get_session_id(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [] -> :none
      [id] -> if valid_session_id?(id), do: {:ok, id}, else: :invalid
      _many -> :invalid
    end
  end

  # Visible ASCII, 0x21 to 0x7E (the spec); the 128-byte limit is a
  # choice of the library.
  #
  @doc false
  @spec valid_session_id?(binary()) :: boolean()
  def valid_session_id?(id) do
    byte_size(id) in 1..@max_session_id_bytes and
      id |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x21..0x7E))
  end

  # -------------------------------------------------------------------
  # Restore of a session that is only in the snapshot store
  # -------------------------------------------------------------------

  # The only place where a request can start a session from a snapshot.
  # It runs before the session stages, which read the Registry only.
  #
  @spec restore(Context.t()) :: Pipeline.result()
  def restore(%{session_id: nil} = context), do: {:cont, context}

  def restore(%{rpc_method: rpc_method} = context)
      when rpc_method in @no_session_methods,
      do: {:cont, context}

  def restore(context) do
    with :enabled <- Sessions.restore_mode(context.instance, context.config),
         {:error, :no_session} <- Sessions.lookup(context.instance, context.session_id) do
      restore_from_snapshot(context)
    else
      :disabled -> {:cont, context}
      {:ok, _view} -> {:cont, context}
      {:error, :unavailable} = answer -> finish(read_failure(context, answer))
      other -> unexpected(context, "Sessions.lookup/2", other)
    end
  end

  # A snapshot not found, a failure, or a wrong shape: the stage passes
  # and the session stage refuses with `404`.
  #
  defp restore_from_snapshot(context) do
    %{instance: instance, session_id: id} = context

    case Sessions.fetch_snapshot(instance, id, context.config) do
      {:ok, snapshot} -> start_if_owner(context, snapshot)
      :disabled -> {:cont, context}
      :not_found -> {:cont, context}
      {:error, :failed} -> {:cont, context}
      {:error, :invalid} -> {:cont, context}
      {:error, :unavailable} = answer -> finish(read_failure(context, answer))
      other -> unexpected(context, "Sessions.fetch_snapshot/2", other)
    end
  end

  # The owner check runs before the start: a foreign principal must not
  # start a session that it does not own.
  #
  defp start_if_owner(context, snapshot) do
    case owner(context, snapshot) do
      %{error: nil} = owned ->
        start_restored(owned, snapshot)

      refused ->
        restore_event(context, :denied)
        finish(refused)
    end
  end

  # A DELETE ends the session at once and holds no slot, so the principal
  # limit is not applied; `max_sessions` still applies, with no reclaim.
  #
  defp start_restored(context, snapshot) do
    delete? = context.conn.method == "DELETE"
    opts = [principal_limit: not delete?, reclaim: not delete?, config: context.config]

    case Sessions.start_restored(context.instance, context.session_id, snapshot, opts) do
      {:ok, _view} ->
        restore_event(context, :restored)
        {:cont, context}

      {:error, :too_many_sessions} ->
        restore_event(context, :limit)
        Pipeline.halt(context, :http_too_many_sessions)

      {:error, :unavailable} = answer ->
        restore_event(context, :unavailable)
        finish(read_failure(context, answer))

      other ->
        unexpected(context, "Sessions.start_restored/4", other)
    end
  end

  # The id of the session never goes out.
  #
  defp restore_event(context, outcome) do
    Telemetry.event(context.conn.private[:oz_mcp_telemetry], :session_restore, %{count: 1}, %{
      outcome: outcome
    })
  end

  # -------------------------------------------------------------------
  # Validate HTTP session
  # -------------------------------------------------------------------

  @spec session(Context.t()) :: Pipeline.result()
  def session(%{rpc_method: "notifications/initialized"} = context) do
    #
    # A principal that does not own the session cannot start it.
    #
    case Sessions.state(context.instance, context.session_id) do
      {:ok, %{initialized: false} = state} ->
        finish(owned(context, state))

      # A second notifications/initialized of the owner is accepted and
      # ignored: a refusal would make the client start a new session.
      #
      {:ok, %{initialized: true} = state} ->
        case owned(context, state) do
          %{error: nil} = owned -> {:cont, Map.put(owned, :session_initialized, true)}
          refused -> finish(refused)
        end

      {:error, :no_session} ->
        Pipeline.halt(context, :http_invalid_session)

      {:error, :unavailable} = answer ->
        finish(read_failure(context, answer))

      other ->
        unexpected(context, "Sessions.state/2", other)
    end
  end

  # ping needs no initialized session, but a session id that it carries
  # must exist and belong to the caller.
  #
  def session(%{rpc_method: "ping", session_id: nil} = context), do: {:cont, context}

  def session(%{rpc_method: "ping"} = context) do
    case Sessions.state(context.instance, context.session_id) do
      {:ok, state} ->
        finish(owned(context, state))

      {:error, :no_session} ->
        Pipeline.halt(context, :http_invalid_session)

      {:error, :unavailable} = answer ->
        finish(read_failure(context, answer))

      other ->
        unexpected(context, "Sessions.state/2", other)
    end
  end

  def session(%{rpc_method: rpc_method} = context)
      when rpc_method in @no_session_methods,
      do: {:cont, context}

  def session(context) do
    case Sessions.state(context.instance, context.session_id) do
      {:error, :no_session} ->
        Pipeline.halt(context, :http_invalid_session)

      {:error, :unavailable} = answer ->
        finish(read_failure(context, answer))

      # A session that waits initialization exists: the answer goes only
      # to its owner; a foreign principal gets the refusal of an unknown
      # session.
      #
      {:ok, %{initialized: false} = state} ->
        case owner(context, state) do
          %{error: nil} = owned -> finish(put_waiting_initialization(owned))
          refused -> finish(refused)
        end

      # The capabilities of the client are fixed by `initialize` and
      # travel in the context to the callbacks.
      #
      {:ok, %{initialized: true, client_capabilities: capabilities} = state} ->
        context
        |> Map.put(:client_capabilities, capabilities || %{})
        |> owned(state)
        |> finish()

      other ->
        unexpected(context, "Sessions.state/2", other)
    end
  end

  # The instance does not run: the request fails closed (503).
  #
  defp read_failure(context, {:error, :unavailable}),
    do: Context.put_error(context, :http_unavailable)

  # An answer that no clause knows is a framework defect: the request
  # fails closed and the log holds no session data.
  #
  defp unexpected(context, call, other) do
    Logger.error("session stage: unexpected answer of " <> call <> ": " <> Guard.shape(other))
    Pipeline.halt(context, :http_unavailable)
  end

  # The answer depends on the mode of the context.
  #
  defp put_waiting_initialization(context) do
    case context.mode do
      :http -> Context.put_error(context, :http_session_waiting_initialization)
      :rpc -> Context.put_error(context, :rpc_session_waiting_initialization)
      _ -> raise "invalid context mode"
    end
  end

  # The DELETE route needs no initialized session, but the caller must
  # own it. The restore stage has already started a restored session.
  #
  @spec session_owner(Context.t()) :: Pipeline.result()
  def session_owner(context) do
    case Sessions.state(context.instance, context.session_id) do
      {:ok, state} ->
        finish(owned(context, state))

      {:error, :no_session} ->
        Pipeline.halt(context, :http_invalid_session)

      {:error, :unavailable} = answer ->
        finish(read_failure(context, answer))

      other ->
        unexpected(context, "Sessions.state/2", other)
    end
  end

  defp finish(%{error: nil} = context), do: {:cont, context}

  defp finish(%{error: error} = context) when not is_nil(error), do: {:halt, context}

  defp owner(%{principal: nil} = context, _session), do: context

  defp owner(context, %{principal_key: key}) do
    if key == Principal.key(context.principal) do
      context
    else
      #
      # The reply is the same as for an unknown session: it confirms
      # nothing about the id. The log keeps no subject and no id.
      #
      Logger.warning("session owner mismatch")
      Context.put_error(context, :http_invalid_session)
    end
  end

  # The owner check goes first: a foreign principal learns nothing about
  # the session.
  #
  defp owned(context, state) do
    case owner(context, state) do
      %{error: nil} = context -> same_protocol_version(context, state)
      refused -> refused
    end
  end

  # The header was checked earlier; here it is compared with the version
  # of the session. No header, or no stored version, passes.
  #
  defp same_protocol_version(%{conn: nil} = context, _state), do: context

  defp same_protocol_version(context, %{protocol_version: session_version})
       when is_binary(session_version) do
    case get_req_header(context.conn, "mcp-protocol-version") do
      [header | _] when header != session_version ->
        Context.put_error(context, :http_protocol_version_mismatch)

      _ ->
        context
    end
  end

  defp same_protocol_version(context, _state), do: context

  # The session belongs to the caller here. The principal must hold all
  # the scopes of the entity, else the answer is 403 with a challenge.
  # `authorize/3` runs after this stage. `resources/unsubscribe` is never
  # checked: a caller can always remove its own subscription.
  #
  @spec required_scopes(Context.t()) :: Pipeline.result()
  def required_scopes(%{principal: nil} = context), do: {:cont, context}

  def required_scopes(%{bound: %Bound{required_scopes: []}} = context), do: {:cont, context}

  def required_scopes(%{bound: %Bound{required_scopes: scopes}} = context) do
    if Scopes.granted?(context.principal, scopes) do
      {:cont, context}
    else
      refuse_scope(context, scopes, nil, :required_scopes)
    end
  end

  # `initialize` is checked here: `authorize/1` skips it and no session
  # exists yet. A pipeline must run both stages.
  #
  @spec authorize_initialize(Context.t()) :: Pipeline.result()
  def authorize_initialize(%{rpc_method: "initialize"} = context), do: run_authorize(context)

  def authorize_initialize(context), do: {:cont, context}

  # The application decides whether the principal may do it. A refusal
  # of scope becomes a 403 whose WWW-Authenticate header carries the
  # scopes to ask for.
  #
  @spec authorize(Context.t()) :: Pipeline.result()
  def authorize(%{rpc_method: "initialize"} = context), do: {:cont, context}

  def authorize(context), do: run_authorize(context)

  defp run_authorize(%{principal: nil} = context), do: {:cont, context}

  defp run_authorize(%{rpc_method: nil} = context), do: {:cont, context}

  defp run_authorize(context) do
    verifier = authorization(context).verifier

    if function_exported?(verifier, :authorize, 3) do
      #
      # `initialize` is authorized before the bind stage, so the callback
      # gets a :none bound entity that holds the params.
      #
      bound = context.bound || %Bound{kind: :none, params: context.rpc_params || %{}}

      call = fn ->
        verifier.authorize(context.principal, context.rpc_method, bound)
      end

      case Guard.call("authorize/3", call) do
        {:ok, result} ->
          refuse_or_pass(context, result)

        # A raise, a throw or an exit in the application is a defect, not
        # a refusal: the request gets a server error, never a pass.
        #
        :failed ->
          refused(context, :authorize, :verifier_error)
          Pipeline.halt(context, :http_internal_error)
      end
    else
      {:cont, context}
    end
  end

  defp authorization(%{config: %OzMcp.Instance.Config{authorization: %{} = auth}}), do: auth

  defp authorization(context), do: Gate.config(context.instance)

  defp refuse_or_pass(context, :ok), do: {:cont, context}

  defp refuse_or_pass(context, {:error, {:insufficient_scope, scopes}}),
    do: refuse_scope(context, scopes, nil, :authorize)

  defp refuse_or_pass(context, {:error, {:insufficient_scope, scopes, description}}),
    do: refuse_scope(context, scopes, description, :authorize)

  defp refuse_or_pass(context, {:error, :forbidden}) do
    refused(context, :authorize, :forbidden)
    Pipeline.halt(context, :http_forbidden)
  end

  # Any other answer fails closed; the log holds the shape only.
  #
  defp refuse_or_pass(context, other) do
    Logger.error("authorize/3 returned an invalid value: " <> Guard.shape(other))
    refused(context, :authorize, :verifier_error)
    Pipeline.halt(context, :http_internal_error)
  end

  # The challenge travels in the WWW-Authenticate header. The scope
  # parameter is the union of the scopes of the principal and the needed
  # scopes, so a new token keeps the scopes it had.
  #
  defp refuse_scope(context, needed, description, stage) do
    challenge_scopes = Gate.config(context.instance).challenge_scopes
    scopes = Scopes.step_up(context.principal, needed, challenge_scopes)

    case build_scope_challenge(scopes, description) do
      {:ok, challenge} ->
        refused(context, stage, :insufficient_scope)
        {:ok, config} = OzMcp.Instance.config(context.instance, context)

        header =
          Gate.header(challenge, context.instance, config.opts.resource_metadata_url)

        Pipeline.halt(context, :http_insufficient_scope, nil, [{"www-authenticate", header}])

      :error ->
        refused(context, stage, :verifier_error)
        Pipeline.halt(context, :http_internal_error)
    end
  end

  # The message of the error names the field, never the value.
  #
  defp build_scope_challenge(scopes, description) do
    {:ok, Challenge.insufficient_scope(scopes, description)}
  rescue
    error in ArgumentError ->
      Logger.error("authorize/3 returned an invalid value: " <> Exception.message(error))
      :error
  end

  # The metadata holds the stage and the reason only: never a token, a
  # subject or a scope string.
  #
  defp refused(context, stage, reason) do
    Telemetry.event(context.conn.private[:oz_mcp_telemetry], :auth_refused, %{count: 1}, %{
      stage: stage,
      reason: reason
    })
  end
end
