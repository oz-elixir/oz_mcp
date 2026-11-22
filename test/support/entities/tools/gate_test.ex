#
# Test support tool that blocks the callback until the test opens the
# gate: it tells the test when it starts (with its own pid) and when it
# ends, so the test can open the gate and watch the process of the
# callback.
#
# The gate is the `receive` in `call/2` where the callback waits for a
# `{:gate, ref}` message: the test opens the gate when it sends that
# message to the pid it got in `{ref, :started, pid}`.
#
# The arm of the gate is one `{pid, ref}` pair under
# `{__MODULE__, instance}` in `:persistent_term`: a test arms the
# instance that it started, so tests that run at the same time never
# share a gate. The test erases the pair when it ends.
#
# When the request carries a progress token, the tool reports one step of
# progress before it waits: the response of the POST becomes an event
# stream and the client holds the id of the last event to resume the
# stream after a lost connection.
#
defmodule Support.Entities.Tools.GateTest do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.Tool

  def list do
    list = [
      %Tool{}
      |> Tool.name("gate")
      |> Tool.description("Waits until the test opens the gate, then ends")
    ]

    list
  end

  def call(ctx, _params) do
    {test_pid, ref} = :persistent_term.get({__MODULE__, Map.get(ctx, :instance)})
    send(test_pid, {ref, :started, self()})

    OzMcp.Notify.progress(ctx, 1, total: 2, message: "gate step")

    receive do
      {:gate, ^ref} -> :ok
    after
      10_000 -> :ok
    end

    send(test_pid, {ref, :finished})
    {:ok, %{content: [%{type: "text", text: "gate done"}]}}
  end

  # The test arms the gate of its instance before it calls the tool and
  # erases the pair when it ends: the pid of an ended test process must
  # not answer the gate of a later test.
  #
  def arm(instance, ref), do: :persistent_term.put({__MODULE__, instance}, {self(), ref})

  def disarm(instance), do: :persistent_term.erase({__MODULE__, instance})
end
