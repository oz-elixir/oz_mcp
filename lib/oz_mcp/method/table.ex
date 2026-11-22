defmodule OzMcp.Method.Table do
  @moduledoc false

  alias OzMcp.Handler.{
    Completion,
    Lifecycle,
    Lists,
    Notifications,
    Prompts,
    Resources,
    TaskMethods,
    Tools
  }

  alias OzMcp.Method

  @methods [
    %Method{name: "initialize", run: {Lifecycle, :initialize}},
    %Method{name: "ping", run: {Lifecycle, :ping}},
    %Method{
      name: "logging/setLevel",
      run: {Lifecycle, :set_level},
      gates: [:logging],
      params: :required
    },
    %Method{name: "notifications/initialized", run: {Notifications, :initialized}},
    %Method{name: "notifications/cancelled", run: {Notifications, :cancelled}},
    %Method{name: "notifications/roots/list_changed", run: {Notifications, :roots_list_changed}},
    %Method{name: "notifications/tasks/status", run: {Notifications, :tasks_status}},
    %Method{name: "tools/list", run: {Lists, :tools}, gates: [:tools]},
    %Method{
      name: "tools/call",
      run: {Tools, :call},
      gates: [:tools],
      params: :required,
      bind: :tool,
      streaming: true
    },
    %Method{name: "prompts/list", run: {Lists, :prompts}, gates: [:prompts]},
    %Method{
      name: "prompts/get",
      run: {Prompts, :get},
      gates: [:prompts],
      params: :required,
      bind: :prompt,
      streaming: true
    },
    %Method{name: "resources/list", run: {Lists, :resources}, gates: [:resources]},
    %Method{name: "resources/templates/list", run: {Lists, :templates}, gates: [:resources]},
    %Method{
      name: "resources/read",
      run: {Resources, :read},
      gates: [:resources],
      params: :required,
      bind: :resource,
      streaming: true
    },
    %Method{
      name: "resources/subscribe",
      run: {Resources, :subscribe},
      gates: [:resources, :resources_subscribe],
      params: :required,
      bind: :resource
    },
    %Method{
      name: "resources/unsubscribe",
      run: {Resources, :unsubscribe},
      gates: [:resources, :resources_subscribe],
      params: :required,
      bind: :resource_uri
    },
    %Method{
      name: "completion/complete",
      run: {Completion, :complete},
      gates: [:completions],
      params: :required,
      bind: :completion,
      streaming: true
    },
    %Method{
      name: "tasks/get",
      run: {TaskMethods, :get},
      gates: [:tasks],
      params: :required,
      bind: :task
    },
    %Method{
      name: "tasks/list",
      run: {TaskMethods, :list},
      gates: [:tasks, :tasks_list],
      bind: :task_list
    },
    %Method{
      name: "tasks/cancel",
      run: {TaskMethods, :cancel},
      gates: [:tasks, :tasks_cancel],
      params: :required,
      bind: :task
    },
    %Method{
      name: "tasks/result",
      run: {TaskMethods, :result},
      gates: [:tasks],
      params: :required,
      bind: :task,
      streaming: true
    }
  ]

  @by_name Map.new(@methods, &{&1.name, &1})

  @spec fetch(term()) :: {:ok, Method.t()} | :error
  def fetch(name) when is_binary(name), do: Map.fetch(@by_name, name)
  def fetch(_name), do: :error

  @spec names() :: [String.t()]
  def names, do: Enum.map(@methods, & &1.name)

  @spec all() :: [Method.t()]
  def all, do: @methods
end
