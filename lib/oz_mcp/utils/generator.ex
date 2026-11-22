#
# Helpers for generating unique identifiers.
#
# All identifiers are built from cryptographically strong random bytes,
# Base64-encoded and stripped of `+`, `/` and `=` characters, so the
# resulting strings are URL-safe and contain only alphanumeric characters.
#
# The requested `size` determines the length of the returned string.
#
defmodule OzMcp.Utils.Generator do
  @moduledoc false

  # Generates a unique session identifier.
  #
  # Returns a URL-safe alphanumeric string of length 40.
  #
  @spec session_id() :: String.t()
  def session_id, do: gen_id(40)

  # Generates a unique task identifier.
  #
  # Returns a URL-safe alphanumeric string of length 32.
  #
  @spec task_id() :: String.t()
  def task_id, do: gen_id(32)

  # Generates the identifier of the event stream of a `POST` request. It is the
  # prefix of the event ids of that stream (see `OzMcp.PostStream`).
  #
  # Returns a URL-safe alphanumeric string of length 10.
  #
  @spec stream_id() :: String.t()
  def stream_id, do: gen_id(10)

  # Generates the identifier of a GET stream. It starts with `g.` so the
  # session tells a GET stream from a POST stream by its event ids.
  #
  # Returns the prefix `g.` and 10 URL-safe alphanumeric characters.
  #
  @spec get_stream_id() :: String.t()
  def get_stream_id, do: "g." <> gen_id(10)

  # Generates the identifier of a request the server sends to the client.
  #
  # Returns a URL-safe alphanumeric string of length 20.
  #
  @spec request_id() :: String.t()
  def request_id, do: gen_id(20)

  # Generates the identifier of an elicitation in URL mode.
  #
  # Returns a URL-safe alphanumeric string of length 20.
  #
  @spec elicitation_id() :: String.t()
  def elicitation_id, do: gen_id(20)

  @doc false
  defp gen_id(size) do
    :crypto.strong_rand_bytes(size * 2)
    |> Base.encode64()
    |> String.replace(["+", "/", "="], "")
    |> String.slice(0, size)
  end
end
