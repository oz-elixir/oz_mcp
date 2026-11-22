defmodule OzMcp.Auth.Principal do
  @moduledoc """
  The authenticated caller.

  The principal never holds the raw bearer token. It holds the identity
  of the caller (`issuer` and `subject`), the granted scopes and the
  claims the application copies from its own token check.

  `audiences` holds the audiences of the token (the `aud` claim of a
  JWT, RFC 7519). Give `nil`, one string, or a list of strings: `new!/1`
  puts one string in a list. OzMcp compares the audiences with the
  `resource_url` of the server (RFC 8707) and refuses a principal whose
  audiences hold no entry for it with `401`, unless the server set
  `audience_check false` in its `authorization` block. A principal with
  no audiences is refused too (fail closed).

  Keep `claims` small. The principal is held by the session and, for
  task-augmented calls, copied into the task record for the life of the
  task. Copy only the claims the callbacks need.

  `expires_at` is Unix time in seconds, as the `exp` claim of a JWT. A
  number with a fraction is allowed. A very large value is a valid time
  that is far in the future: the computations of `expires_in/2` and
  `expired?/2` never raise for a number. OzMcp reads the field in two places:
  the gate refuses a principal that is expired and a `GET` stream ends when
  its principal expires. The clock of the server decides. If the clocks of
  the issuer and of the server can differ, subtract a margin from `exp`.
  """

  @enforce_keys [:subject]

  defstruct subject: nil,
            issuer: nil,
            client_id: nil,
            scopes: [],
            audiences: nil,
            claims: %{},
            expires_at: nil

  @type t :: %__MODULE__{
          subject: String.t(),
          issuer: String.t() | nil,
          client_id: String.t() | nil,
          scopes: [String.t()],
          audiences: [String.t()] | nil,
          claims: map(),
          expires_at: number() | nil
        }

  @doc """
  Build a principal from keyword attributes or a map. Raises
  `ArgumentError` when the subject is not a non-empty string, when the
  issuer is neither a string nor `nil`, when the scopes are not a list of
  strings, when `audiences` is neither a string, a list of strings nor
  `nil`, when `expires_at` is neither a number nor `nil`, or when an
  unknown attribute is given.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    principal = struct!(__MODULE__, attrs)

    if not (is_binary(principal.subject) and principal.subject != "") do
      raise ArgumentError, "principal subject must be a non-empty string"
    end

    if not (is_nil(principal.issuer) or is_binary(principal.issuer)) do
      raise ArgumentError, "principal issuer must be a string or nil"
    end

    if not (is_list(principal.scopes) and Enum.all?(principal.scopes, &is_binary/1)) do
      raise ArgumentError, "principal scopes must be a list of strings"
    end

    principal = Map.update!(principal, :audiences, &normalize_audiences!/1)

    if not (is_nil(principal.expires_at) or is_number(principal.expires_at)) do
      raise ArgumentError,
            "principal expires_at must be a number (Unix time in seconds) or nil"
    end

    principal
  end

  defp normalize_audiences!(nil), do: nil
  defp normalize_audiences!(audience) when is_binary(audience), do: [audience]

  defp normalize_audiences!(audiences) when is_list(audiences) do
    if Enum.all?(audiences, &is_binary/1),
      do: audiences,
      else: raise(ArgumentError, "principal audiences must be a string, a list of strings or nil")
  end

  defp normalize_audiences!(_other),
    do: raise(ArgumentError, "principal audiences must be a string, a list of strings or nil")

  @doc """
  Milliseconds until the principal expires. The result is zero or negative
  when the principal is expired. It is `nil` when the principal has no
  expiry.

  `expires_at` is Unix time in seconds, as the `exp` claim of a JWT.
  """
  @spec expires_in(t(), integer()) :: integer() | nil
  def expires_in(principal, now_ms \\ System.system_time(:millisecond))

  def expires_in(%__MODULE__{expires_at: expires_at}, now_ms) when is_number(expires_at),
    do: to_milliseconds(expires_at) - now_ms

  def expires_in(%__MODULE__{}, _now_ms), do: nil

  # Seconds to milliseconds with no float multiplication of a big number.
  # `trunc/1` of a float gives an integer and an integer does not
  # overflow. The fraction is small, so its product is safe.
  #
  defp to_milliseconds(seconds) do
    whole = trunc(seconds)
    whole * 1000 + trunc((seconds - whole) * 1000)
  end

  @doc """
  True when the principal has an expiry and it is not in the future.
  """
  @spec expired?(t(), integer()) :: boolean()
  def expired?(principal, now_ms \\ System.system_time(:millisecond)) do
    case expires_in(principal, now_ms) do
      nil -> false
      ms -> ms <= 0
    end
  end

  @doc """
  The key that binds a session to a principal: `{issuer, subject}`.
  """
  @spec key(t()) :: {String.t() | nil, String.t()}
  def key(%__MODULE__{issuer: issuer, subject: subject}), do: {issuer, subject}

  @doc """
  True when the principal holds every needed scope. Accepts one scope or
  a list of scopes.
  """
  @spec scope?(t(), String.t() | [String.t()]) :: boolean()
  def scope?(%__MODULE__{scopes: have}, need) when is_list(need),
    do: Enum.all?(need, &(&1 in have))

  def scope?(principal, need), do: scope?(principal, [need])
end
