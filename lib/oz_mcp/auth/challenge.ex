defmodule OzMcp.Auth.Challenge do
  @moduledoc """
  A refusal of a request. It becomes an HTTP status and a
  `WWW-Authenticate` header value.
  """

  defstruct error: nil, description: nil, scopes: []

  @type error :: nil | :invalid_token | :invalid_request | :insufficient_scope

  @type t :: %__MODULE__{
          error: error(),
          description: String.t() | nil,
          scopes: [String.t()]
        }

  @description_max 200

  # The error code of each error value. from/1 accepts a challenge only
  # when its error is a key of the table, so an unknown error fails
  # closed instead of reaching a response header.
  #
  @errors %{
    nil => :http_unauthorized,
    :invalid_token => :http_unauthorized,
    :invalid_request => :http_bad_authorization,
    :insufficient_scope => :http_insufficient_scope
  }

  @doc """
  The request carries no usable bearer credential. HTTP 401 without an
  error parameter (RFC 6750, section 3.1).
  """
  @spec missing_token() :: t()
  def missing_token, do: %__MODULE__{}

  @doc """
  The bearer token is not valid. HTTP 401. Raises `ArgumentError` when
  the description is neither a string nor nil.
  """
  @spec invalid_token(String.t() | nil) :: t()
  def invalid_token(description \\ nil) do
    check_description!(description, "invalid_token/1 expects a string or nil as description")
    %__MODULE__{error: :invalid_token, description: description}
  end

  @doc """
  The request is malformed. HTTP 400. Raises `ArgumentError` when the
  description is neither a string nor nil.
  """
  @spec invalid_request(String.t() | nil) :: t()
  def invalid_request(description \\ nil) do
    check_description!(description, "invalid_request/1 expects a string or nil as description")
    %__MODULE__{error: :invalid_request, description: description}
  end

  @doc """
  The token is valid but misses scopes. HTTP 403. Raises `ArgumentError`
  when a scope does not match the RFC 6749 scope-token syntax, when the
  scopes are not a list, or when the description is neither a string nor
  nil.
  """
  @spec insufficient_scope([String.t()], String.t() | nil) :: t()
  def insufficient_scope(scopes, description \\ nil) do
    check_description!(description, "insufficient_scope/2 expects a string or nil as description")

    if valid_scopes?(scopes) do
      %__MODULE__{error: :insufficient_scope, scopes: scopes, description: description}
    else
      raise ArgumentError,
            "insufficient_scope expects RFC 6749 scope tokens " <>
              "(printable ASCII without space, double quote and backslash)"
    end
  end

  @doc """
  Turn the shortcut atoms that the `authenticate/2` contract allows into
  a challenge and check a challenge: an unknown error, a description
  that is not a string or nil and scopes that are not a list of scope
  tokens are defects of the verifier. Any such value raises
  `ArgumentError` and the caller must answer a server error, never a
  pass.
  """
  @spec from(t() | atom()) :: t()
  def from(%__MODULE__{error: error} = challenge) when is_map_key(@errors, error) do
    check_description!(
      challenge.description,
      "authenticate/2 returned a challenge with a description that is not a string or nil"
    )

    check_scopes!(
      challenge.scopes,
      "authenticate/2 returned a challenge with scopes that are not a list of RFC 6749 scope tokens"
    )

    challenge
  end

  def from(%__MODULE__{error: error}) do
    raise ArgumentError,
          "authenticate/2 returned a challenge with an unknown error: " <> describe_error(error)
  end

  def from(:missing_token), do: missing_token()
  def from(:invalid_token), do: invalid_token()
  def from(:invalid_request), do: invalid_request()

  def from(other) when is_atom(other) do
    raise ArgumentError,
          "authenticate/2 returned the shortcut atom #{inspect(other)}, " <>
            "but only :missing_token, :invalid_token and :invalid_request are challenges"
  end

  # The log names an atom. It names only the type of another value.
  #
  defp describe_error(error) when is_atom(error), do: inspect(error)
  defp describe_error(_error), do: "not an atom"

  @doc "The key of the internal error table of the context for the challenge."
  @spec error_code(t()) :: :http_unauthorized | :http_bad_authorization | :http_insufficient_scope
  def error_code(%__MODULE__{error: error}), do: Map.fetch!(@errors, error)

  @doc """
  Build the `WWW-Authenticate` value of the challenge.

  `metadata_url` is the Protected Resource Metadata URL of the server.
  `default_scopes` are used when the challenge holds no scopes of its
  own. The description is cut to #{@description_max} characters. Each
  character that the header cannot hold becomes `?`.
  """
  @spec header(t(), String.t() | nil, [String.t()]) :: String.t()
  def header(%__MODULE__{} = challenge, metadata_url, default_scopes \\ []) do
    scopes = if challenge.scopes == [], do: default_scopes, else: challenge.scopes

    params =
      [
        {"error", challenge.error && Atom.to_string(challenge.error)},
        {"error_description",
         challenge.description &&
           String.slice(printable(challenge.description), 0, @description_max)},
        {"scope", scopes != [] && Enum.join(scopes, " ")},
        {"resource_metadata", metadata_url}
      ]
      |> Enum.filter(fn {_key, value} -> is_binary(value) end)
      |> Enum.map_join(", ", fn {key, value} -> ~s(#{key}="#{printable(value)}") end)

    if params == "", do: "Bearer", else: "Bearer " <> params
  end

  defp scope_token?(scope), do: OzMcp.Auth.scope_token?(scope)

  # The checks of a challenge built from the values of the application:
  # the caller gives the full message and the message names the field,
  # never the value.
  #
  defp check_description!(description, _message)
       when is_binary(description) or is_nil(description),
       do: :ok

  defp check_description!(_description, message), do: raise(ArgumentError, message)

  defp check_scopes!(scopes, message) do
    if valid_scopes?(scopes), do: :ok, else: raise(ArgumentError, message)
  end

  # An improper list, or any other value, gives false: Enum.all?/2 would
  # raise for an improper list.
  #
  defp valid_scopes?([]), do: true
  defp valid_scopes?([scope | rest]), do: scope_token?(scope) and valid_scopes?(rest)
  defp valid_scopes?(_other), do: false

  # Keep only the characters RFC 6750 allows inside a quoted string
  # parameter: no double quote, no backslash, no control byte. Any other
  # character becomes "?". replace_invalid/2 runs first: the u flag of
  # the pattern raises for a binary that is not UTF-8 and the
  # description comes from the application.
  #
  defp printable(text) do
    text
    |> String.replace_invalid("?")
    |> String.replace(~r/[^ !#-\[\]-~]/u, "?")
  end
end
