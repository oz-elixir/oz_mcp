defmodule OzMcp.SnapshotSizeTest do
  use ExUnit.Case, async: true

  # The ceiling of the lines of the snapshot and restore code. A change that
  # needs more lines raises the number in the same commit and the commit
  # message gives the reason. The limit of the sessions now passes the
  # reclaim option to the start from a snapshot.
  #
  @ceiling 1019

  # Gate of 1.0: the owner reads the history of this ceiling before the
  # tag and writes the final number in the changelog of 1.0.
  #

  @files [
           "lib/oz_mcp/session/snapshot.ex",
           "lib/oz_mcp/session/restore_cache.ex",
           "lib/oz_mcp/session/persistence.ex"
         ] ++ Path.wildcard("lib/oz_mcp/session/snapshot/*.ex")

  @stage_file "lib/oz_mcp/validate/http.ex"
  @stage_start "Restore of a session that is only in the snapshot store"
  @stage_end "# Validate HTTP session"

  defp line_count(path), do: path |> File.stream!() |> Enum.count()

  # The restore stage is the part of validate/http.ex between two banners.
  #
  defp stage_lines do
    {_before, in_and_after} = File.read!(@stage_file) |> split_at(@stage_start)
    {stage, _after} = split_at(in_and_after, @stage_end)
    length(String.split(stage, "\n")) - 1
  end

  defp split_at(text, marker) do
    case String.split(text, marker, parts: 2) do
      [a, b] -> {a, b}
      [_] -> flunk("marker not found: #{marker}")
    end
  end

  test "the seven snapshot files are all found" do
    assert length(@files) == 7
  end

  test "the snapshot and restore code stays under the ceiling" do
    total = @files |> Enum.map(&line_count/1) |> Enum.sum()
    total = total + stage_lines()

    assert total <= @ceiling,
           "#{total} lines of snapshot and restore code (ceiling: #{@ceiling}). " <>
             "Raise @ceiling in the same commit and give the reason."
  end
end
