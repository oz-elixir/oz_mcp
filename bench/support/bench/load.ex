#
# The concurrent load of the benchmark: N sessions in parallel for a fixed
# time. Each session has one `GET` stream and one worker that loops
# `tools/call` requests to `slow_echo` with a `progressToken`, so each
# answer is an event stream with three progress reports.
#
# The load runs in process through `Plug.Test`, like the other scenarios:
# no socket and no HTTP server. The throughput and the scheduler
# utilization include the client side, because the bench processes build
# and send each request on the same node.
#
defmodule Bench.Load do
  import Plug.Conn
  import Plug.Test

  alias Bench.Runner

  @router OzMcp.Router
  @protocol_version "2025-11-25"

  # The reads of the memory are close when they differ by 256 KiB or less.
  #
  @settle_bytes 262_144
  @settle_tries 25

  # The parent waits this long for all the streams to attach.
  #
  @attach_timeout_ms 30_000

  # Runs `sessions` sessions in parallel against `instance` for
  # `duration_ms` and returns the row `load_1k`.
  #
  # `count` is the number of requests done, `total_ms` the wall time of the
  # window and the latencies are in microseconds. `utilization` is the
  # scheduler utilization in percent over the window and
  # `memory_per_session_bytes` the growth of the VM memory from before the
  # sessions open to after all the streams are attached, divided by
  # `sessions`. It includes the `GET` processes of the bench.
  #
  # A request that answers an error stops the run after the window.
  #
  @spec run(OzMcp.Instance.t(), pos_integer(), pos_integer()) :: Runner.row()
  def run(instance, sessions, duration_ms) do
    before = memory()
    ids = for _ <- 1..sessions, do: Runner.initialized_session(instance)
    streams = Enum.map(ids, &start_stream(instance, &1))

    try do
      await_attached(instance, ids)
      memory_per_session = div(memory() - before, sessions)

      probe!(instance, hd(ids))

      :erlang.system_flag(:scheduler_wall_time, true)

      # The first sample after the flag comes back empty on some versions:
      # take one and drop it.
      #
      _ = :erlang.statistics(:scheduler_wall_time)
      first = :erlang.statistics(:scheduler_wall_time)

      deadline = System.monotonic_time(:millisecond) + duration_ms
      started = System.monotonic_time(:microsecond)

      results =
        ids
        |> Enum.map(&Task.async(fn -> loop(instance, &1, deadline, [], 0) end))
        |> Task.await_many(duration_ms + 60_000)

      wall_us = System.monotonic_time(:microsecond) - started
      second = :erlang.statistics(:scheduler_wall_time)

      bad = results |> Enum.map(fn {_samples, bad} -> bad end) |> Enum.sum()

      if bad > 0 do
        raise "#{bad} benchmark requests of the load answered an error"
      end

      row(results, sessions, wall_us, utilization(first, second), memory_per_session)
    after
      Enum.each(ids, &Runner.delete(instance, &1))
      await_down(streams)
    end
  end

  defp row(results, sessions, wall_us, utilization, memory_per_session) do
    sorted = results |> Enum.flat_map(fn {samples, _bad} -> samples end) |> Enum.sort()
    count = length(sorted)

    %{
      name: "load_1k",
      count: count,
      total_ms: div(wall_us, 1000),
      per_second: round(count * 1_000_000 / max(wall_us, 1)),
      p50: Runner.percentile(sorted, 0.50),
      p95: Runner.percentile(sorted, 0.95),
      p99: Runner.percentile(sorted, 0.99),
      sessions: sessions,
      utilization: utilization,
      memory_per_session_bytes: memory_per_session
    }
  end

  # ---- Streams ----

  # The router call of a `GET` returns when the stream ends: one process
  # per stream owns the call.
  #
  defp start_stream(instance, session_id) do
    {pid, ref} =
      spawn_monitor(fn ->
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", @protocol_version)
        |> @router.call(@router.init(instance: instance))
      end)

    {pid, ref}
  end

  # The session puts `streams: 1` in its view before it answers the
  # attach and the lookup does not call the session.
  #
  defp await_attached(instance, ids) do
    deadline = System.monotonic_time(:millisecond) + @attach_timeout_ms
    Enum.each(ids, &await_stream(instance, &1, deadline))
  end

  defp await_stream(instance, session_id, deadline) do
    case OzMcp.Sessions.lookup(instance, session_id) do
      {:ok, %{streams: 1}} ->
        :ok

      _other ->
        if System.monotonic_time(:millisecond) > deadline do
          raise "the GET stream of session #{session_id} did not attach in time"
        end

        Process.sleep(5)
        await_stream(instance, session_id, deadline)
    end
  end

  defp await_down(streams) do
    Enum.each(streams, fn {pid, ref} ->
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        @attach_timeout_ms -> raise "a GET process of the load did not end"
      end
    end)
  end

  # ---- Requests ----

  defp request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => "slow_echo",
        "arguments" => %{"text" => "load"},
        "_meta" => %{"progressToken" => id}
      }
    }
  end

  # One request before the window, with the answer decoded: the load must
  # measure the path of a good answer.
  #
  defp probe!(instance, session_id) do
    conn = Runner.post(instance, session_id, request(0))

    if conn.status != 200 or not String.contains?(conn.resp_body, ~s("text":"load")) do
      raise "the probe request of the load did not answer a result (status #{conn.status})"
    end
  end

  defp loop(instance, session_id, deadline, samples, bad) do
    if System.monotonic_time(:millisecond) >= deadline do
      {samples, bad}
    else
      {us, conn} = :timer.tc(fn -> Runner.post(instance, session_id, request(1)) end)
      flush()
      bad = if good?(conn), do: bad, else: bad + 1
      loop(instance, session_id, deadline, [us | samples], bad)
    end
  end

  # No decode: the body is an event stream and the check only looks for
  # an error member or `isError: true`.
  #
  defp good?(%Plug.Conn{status: 200, resp_body: body}) when is_binary(body) do
    not (String.contains?(body, ~s("error":)) or String.contains?(body, ~s("isError":true)))
  end

  defp good?(_conn), do: false

  # Each `Plug.Test` response leaves two messages in the caller. The read
  # is out of the timed call.
  #
  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end

  # ---- Measures ----

  # The memory that other scenarios freed late (the sessions of a scenario
  # that ended) would show as a negative growth: read the total after a
  # GC of all processes and read again until two reads are close.
  #
  defp memory, do: settle(garbage_collected_memory(), @settle_tries)

  defp settle(previous, 0), do: previous

  defp settle(previous, tries) do
    Process.sleep(200)
    current = garbage_collected_memory()

    if abs(current - previous) <= @settle_bytes, do: current, else: settle(current, tries - 1)
  end

  defp garbage_collected_memory do
    Enum.each(Process.list(), &:erlang.garbage_collect/1)
    :erlang.memory(:total)
  end

  # The busy share (percent) of the normal schedulers between two wall time samples.
  #
  @spec utilization([{pos_integer(), integer(), integer()}], [
          {pos_integer(), integer(), integer()}
        ]) :: float()
  def utilization(first, second) do
    normal = :erlang.system_info(:schedulers)

    {active, total} =
      Enum.zip(Enum.sort(first), Enum.sort(second))
      |> Enum.filter(fn {{id, _a1, _t1}, _} -> id <= normal end)
      |> Enum.reduce({0, 0}, fn {{_id, a1, t1}, {_id2, a2, t2}}, {a, t} ->
        {a + (a2 - a1), t + (t2 - t1)}
      end)

    if total == 0, do: 0.0, else: active * 100 / total
  end
end
