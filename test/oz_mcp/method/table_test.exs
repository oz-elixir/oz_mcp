#
# The table of the served methods: one row per method, with the gates,
# the params rule, the bind kind and the streaming flag of the method.
#
# The literal list of the names stays in this test as a record of the
# behavior: a row that is lost fails here, instead of a method that the
# telemetry reports as `:unknown`.
#
defmodule OzMcp.Method.TableTest do
  use ExUnit.Case, async: true

  alias OzMcp.Method
  alias OzMcp.Method.Table

  # The served methods, as the handler served them before the table
  # (the list of `OzMcp.Protocol`).
  #
  @served_methods [
    "initialize",
    "ping",
    "notifications/initialized",
    "notifications/cancelled",
    "notifications/roots/list_changed",
    "notifications/tasks/status",
    "resources/list",
    "resources/templates/list",
    "resources/read",
    "resources/subscribe",
    "resources/unsubscribe",
    "tools/list",
    "tools/call",
    "prompts/list",
    "prompts/get",
    "tasks/get",
    "tasks/list",
    "tasks/cancel",
    "tasks/result",
    "logging/setLevel",
    "completion/complete"
  ]

  @known_gates [
    :tools,
    :prompts,
    :resources,
    :resources_subscribe,
    :logging,
    :completions,
    :tasks,
    :tasks_list,
    :tasks_cancel
  ]

  @known_binds [:none, :tool, :prompt, :resource, :resource_uri, :completion, :task, :task_list]

  # The methods whose params must be present, as the validation held
  # them before the table.
  #
  @methods_with_required_params [
    "tools/call",
    "prompts/get",
    "tasks/get",
    "tasks/cancel",
    "tasks/result",
    "resources/read",
    "resources/subscribe",
    "resources/unsubscribe",
    "logging/setLevel",
    "completion/complete"
  ]

  # The methods whose callback can send messages to the client during
  # the request, as `OzMcp.PostStream` held them before the table.
  #
  @streaming_methods [
    "tools/call",
    "resources/read",
    "prompts/get",
    "completion/complete",
    "tasks/result"
  ]

  test "the table holds each served method and no other" do
    assert Enum.sort(Table.names()) == Enum.sort(@served_methods)
  end

  test "the rows with required params are the methods that needed params before the table" do
    required = Table.all() |> Enum.filter(&(&1.params == :required)) |> Enum.map(& &1.name)

    assert Enum.sort(required) == Enum.sort(@methods_with_required_params)
  end

  test "the rows with the streaming flag are the methods that streamed before the table" do
    streaming = Table.all() |> Enum.filter(& &1.streaming) |> Enum.map(& &1.name)

    assert Enum.sort(streaming) == Enum.sort(@streaming_methods)
  end

  test "the names are unique" do
    names = Table.names()
    assert Enum.uniq(names) == names
  end

  test "each gate of each row is a known gate" do
    for %Method{gates: gates} = row <- Table.all() do
      for gate <- gates do
        assert gate in @known_gates, "row #{row.name} holds the unknown gate #{inspect(gate)}"
      end
    end
  end

  test "each bind of each row is a known bind" do
    for %Method{bind: bind} = row <- Table.all() do
      assert bind in @known_binds, "row #{row.name} holds the unknown bind #{inspect(bind)}"
    end
  end

  test "fetch/1 gives the row of a served method" do
    {:ok, %Method{name: name}} = Table.fetch("tools/call")
    assert name == "tools/call"
    {:ok, %Method{}} = Table.fetch("notifications/tasks/status")
  end

  test "fetch/1 gives :error for a method that the table does not hold" do
    assert Table.fetch("x/y") == :error
    assert Table.fetch("") == :error
  end

  test "fetch/1 gives :error for a name that is not a string" do
    assert Table.fetch(42) == :error
    assert Table.fetch(nil) == :error
    assert Table.fetch(:ping) == :error
  end
end
