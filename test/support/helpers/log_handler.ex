#
# A `:logger` handler for `Support.Helpers.Utils.capture_log/2`. It is installed once
# (by `install/0` in `test_helper.exs`) and never removed: adding and
# removing handlers while other tests run makes `Logger.flush/0` fail.
#
# A test registers its pid in an ETS table. The handler runs in the
# process that logs; it keeps an event only when that process is a
# registered test, or was started by one with `Task` (its `$callers`).
# The other tests that run at the same time do not add lines.
#
defmodule Support.Helpers.LogHandler do
  @table :test_log_owners
  @handler_id :test_log_capture

  def install do
    :ets.new(@table, [:named_table, :public, :set])
    :ok = :logger.add_handler(@handler_id, __MODULE__, %{level: :all})
  end

  def register(owner, ref, level), do: :ets.insert(@table, {owner, ref, level})

  def unregister(owner), do: :ets.delete(@table, owner)

  # The logger callback.
  #
  def log(event, _config) do
    case owner() do
      {owner, ref, level} ->
        if :logger.compare_levels(event.level, level) in [:gt, :eq] do
          text =
            :logger_formatter.format(event, %{
              template: ["[", :level, "] ", :msg, "\n"],
              single_line: false
            })

          send(owner, {ref, IO.chardata_to_string(text)})
        end

      nil ->
        :ok
    end

    :ok
  end

  defp owner do
    Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
      case :ets.lookup(@table, pid) do
        [{^pid, ref, level}] -> {pid, ref, level}
        [] -> nil
      end
    end)
  end
end
