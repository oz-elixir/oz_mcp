#
# The authentication step of a protected server: it calls the
# `authenticate/2` callback of the verifier and never trusts it. A wrong
# value, a raise, a throw or an exit is a defect and it fails closed.
#
defmodule OzMcp.Auth.Gate do
  @moduledoc false

  alias OzMcp.Auth.{Audience, Challenge, Guard, Principal}
  alias OzMcp.Telemetry

  require Logger

  @type result ::
          :disabled
          | {:ok, Principal.t()}
          | {:refuse, Challenge.t(), String.t() | nil}
          | :error
          | :not_running

  # The authorization map: `{:ok, map}` or `{:ok, nil}`, or `:not_running`.
  # A given config skips the read of the Registry.
  #
  @spec fetch_config(OzMcp.Instance.t(), OzMcp.Instance.Config.t() | nil) ::
          {:ok, map() | nil} | :not_running
  def fetch_config(instance, config \\ nil) do
    with {:ok, config} <- OzMcp.Instance.config(instance, config),
         do: {:ok, config.authorization}
  end

  # The authorization map, or `nil` when there is none or the instance does
  # not run. A caller that must know the difference uses `fetch_config/2`.
  #
  @spec config(OzMcp.Instance.t()) :: map() | nil
  def config(instance) do
    case fetch_config(instance) do
      {:ok, auth} -> auth
      :not_running -> nil
    end
  end

  # The `WWW-Authenticate` value of a challenge. With no scopes of its own,
  # the challenge gets the `challenge_scopes` of the server.
  #
  @spec header(Challenge.t(), module(), String.t() | nil) :: String.t()
  def header(%Challenge{} = challenge, server, metadata_url),
    do: Challenge.header(challenge, metadata_url, config(server).challenge_scopes)

  # Checks the credentials of the request. A given config supplies the
  # authorization block, the options and the server module.
  #
  @spec run(Plug.Conn.t(), module(), OzMcp.Instance.Config.t() | nil) :: result()
  def run(conn, instance, config \\ nil) do
    case fetch_config(instance, config) do
      {:ok, nil} ->
        :disabled

      {:ok, auth} ->
        authenticate(conn, instance, auth, config)

      :not_running ->
        :not_running
    end
  end

  defp authenticate(conn, instance, auth, config) do
    with {:ok, opts, server} <- invocation(instance, config),
         conn = Plug.Conn.put_private(conn, :oz_mcp_max_token_bytes, opts.max_token_bytes),
         {:ok, result} <-
           Guard.call("authenticate/2", fn -> auth.verifier.authenticate(conn, server) end) do
      check(result, conn, instance, auth, opts)
    else
      #
      # The instance stopped between the two reads of its registration.
      #
      :not_running ->
        Logger.error("authenticate/2 skipped: the runtime does not have the server")
        :not_running

      # The callback raised, threw or exited: Guard logged the type only.
      #
      :failed ->
        refused(conn, :verifier_error)
        :error
    end
  end

  # From the config of the request when the caller has it, else from the
  # Registry.
  #
  defp invocation(_instance, %OzMcp.Instance.Config{} = config),
    do: {:ok, config.opts, config.server}

  defp invocation(instance, nil) do
    with {:ok, opts} <- OzMcp.Instance.fetch_opts(instance),
         do: {:ok, opts, OzMcp.Instance.server_module(instance)}
  end

  defp check({:ok, %Principal{subject: subject} = principal}, conn, server, auth, opts)
       when is_binary(subject) and subject != "" do
    cond do
      #
      # A late token or a clock that differs: the client needs a fresh one.
      #
      Principal.expired?(principal) ->
        refused(conn, :token_expired)
        {:refuse, Challenge.invalid_token("token expired"), opts.resource_metadata_url}

      # RFC 8707: the token must be for this resource, unless the server
      # turned the check off.
      #
      audience_check?(auth) and not Audience.member?(principal.audiences, opts.resource_url) ->
        warn_missing_audiences(server, principal)
        refused(conn, :audience_mismatch)
        {:refuse, Challenge.invalid_token("token audience mismatch"), opts.resource_metadata_url}

      true ->
        {:ok, principal}
    end
  end

  defp check({:error, reason}, conn, _server, _auth, opts)
       when is_atom(reason) or is_struct(reason, Challenge) do
    case refuse(reason, opts) do
      {:refuse, %Challenge{} = challenge, _metadata_url} = answer ->
        refused(conn, challenge_reason(challenge))
        answer

      :error ->
        refused(conn, :verifier_error)
        :error
    end
  end

  defp check(other, conn, _server, _auth, _opts) do
    Logger.error("authenticate/2 returned an invalid value: " <> Guard.shape(other))
    refused(conn, :verifier_error)
    :error
  end

  defp audience_check?(auth), do: Map.get(auth, :audience_check, true)

  # One warning per server: it names the module, never the token or a
  # claim.
  #
  defp warn_missing_audiences(server, %Principal{audiences: nil}) do
    flag = {__MODULE__, server, :missing_audiences}

    if :persistent_term.get(flag, false) == false do
      :persistent_term.put(flag, true)

      Logger.warning(
        "authenticate/2 of #{inspect(OzMcp.Instance.server_module(server))} returned a principal without audiences. " <>
          "Set :audiences, or set audience_check false in the authorization block"
      )
    end
  end

  defp warn_missing_audiences(_server, _principal), do: :ok

  # A shortcut atom the contract does not know makes Challenge.from/1
  # raise: a defect of the verifier, not a refusal.
  #
  defp refuse(reason, opts) do
    {:refuse, Challenge.from(reason), opts.resource_metadata_url}
  rescue
    error in ArgumentError ->
      Logger.error("authenticate/2 returned an invalid value: " <> Exception.message(error))
      :error
  end

  # The metadata holds the stage and the reason only: never a token, a
  # subject or a scope string.
  #
  defp refused(conn, reason) do
    Telemetry.event(conn.private[:oz_mcp_telemetry], :auth_refused, %{count: 1}, %{
      stage: :authenticate,
      reason: reason
    })
  end

  # `nil` means no usable credential; the other values name the defect.
  #
  defp challenge_reason(%Challenge{error: nil}), do: :missing_token
  defp challenge_reason(%Challenge{error: error}) when is_atom(error), do: error
end
