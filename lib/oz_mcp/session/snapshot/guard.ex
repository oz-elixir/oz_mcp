#
# Runs one call of a snapshot module. A raise, a throw, an exit or an
# `{:error, _}` answer is a defect of the module, not of the session: it
# writes a log and gives `{:error, :failed}`. The `:error` log has the
# type of the failure only; the full text is logged at `:debug`.
#
defmodule OzMcp.Session.Snapshot.Guard do
  @moduledoc false

  alias OzMcp.Utils.Log
  require Logger

  @spec call(String.t(), (-> result)) :: result | {:error, :failed} when result: var
  def call(label, fun) when is_binary(label) and is_function(fun, 0) do
    case fun.() do
      {:error, reason} ->
        Logger.error("session snapshot #{label} failed")
        Logger.debug(fn -> "session snapshot #{label} failure: #{inspect(reason)}" end)
        {:error, :failed}

      other ->
        other
    end
  catch
    kind, reason ->
      Logger.error(
        "session snapshot #{label} failed: " <>
          Log.describe(kind, reason, __STACKTRACE__) <>
          "\n" <> Log.format_stacktrace(__STACKTRACE__)
      )

      Logger.debug(fn ->
        "session snapshot #{label} failure text: " <> Log.banner(kind, reason, __STACKTRACE__)
      end)

      {:error, :failed}
  end
end
