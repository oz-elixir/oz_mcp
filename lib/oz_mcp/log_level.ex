defmodule OzMcp.LogLevel do
  @moduledoc """
  The levels of `notifications/message` (RFC 5424 severities), from the
  lowest to the highest.

  A session receives a message when the level of the message is equal to
  or higher than the level that the client set with `logging/setLevel`.
  """

  @levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]

  @rank @levels |> Enum.with_index() |> Map.new()

  @type t :: :debug | :info | :notice | :warning | :error | :critical | :alert | :emergency

  defguard is_level(level) when level in @levels

  @doc """
  The levels, from the lowest to the highest severity.
  """
  @spec levels() :: [t()]
  def levels, do: @levels

  @doc """
  True when a session at `session_level` receives a message at `level`.

  `false` when the session has no level (`nil`) and when one of the two
  values is not a level: a snapshot module can return any value and
  the session must not stop because of it.
  """
  @spec wanted?(term(), term()) :: boolean()
  def wanted?(session_level, level) do
    case {Map.fetch(@rank, session_level), Map.fetch(@rank, level)} do
      {{:ok, session_rank}, {:ok, rank}} -> session_rank <= rank
      _ -> false
    end
  end
end
