#
# A task store that delegates to the default store and fails on demand.
# A test arms a flag for one function of one instance, runs the code
# under test and clears the flag in `on_exit`. The modes are:
#
#   * `:raise`: the call raises.
#   * `:error`: the call answers `{:error, :boom}`.
#   * `:exit`: the call exits.
#
# The message of the raise carries a marker that no log of the runtime
# may repeat: a test can assert that the log of a failure keeps the
# details of the exception out.
#
defmodule Support.TasksStores.Failing do
  @behaviour OzMcp.Tasks.StoreBehaviour

  @marker "secret-client-payload"

  def arm(instance, function, mode \\ :raise),
    do: :persistent_term.put({__MODULE__, instance, function}, mode)

  def clear(instance, function), do: :persistent_term.erase({__MODULE__, instance, function})

  def clear_instance(instance) do
    for {key, _mode} <- :persistent_term.get(),
        match?({__MODULE__, ^instance, _function}, key) do
      :persistent_term.erase(key)
    end

    :ok
  end

  @impl true
  def init(instance), do: call(instance, :init, [instance])

  @impl true
  def put(instance, record), do: call(instance, :put, [instance, record])

  @impl true
  def get(instance, task_id), do: call(instance, :get, [instance, task_id])

  @impl true
  def delete(instance, record), do: call(instance, :delete, [instance, record])

  @impl true
  def page(instance, owner_key, after_seq, limit),
    do: call(instance, :page, [instance, owner_key, after_seq, limit])

  @impl true
  def count_active(instance, scope), do: call(instance, :count_active, [instance, scope])

  @impl true
  def expired(instance, now_ms, limit), do: call(instance, :expired, [instance, now_ms, limit])

  @impl true
  def next_expiry(instance), do: call(instance, :next_expiry, [instance])

  @impl true
  def owner_usage(instance, owner_key), do: call(instance, :owner_usage, [instance, owner_key])

  @impl true
  def active(instance), do: call(instance, :active, [instance])

  defp call(instance, function, args) do
    case :persistent_term.get({__MODULE__, instance, function}, nil) do
      nil ->
        #
        # The store owns its index: every callback that the facade would
        # keep for it must go through the facade itself, with the
        # default store behind it. `active/1` is not an index callback.
        #
        default(function, args)

      :raise ->
        raise RuntimeError, "the store was told to fail in #{function} (#{@marker})"

      :error ->
        {:error, :boom}

      :exit ->
        exit(:boom)
    end
  end

  defp default(:active, args), do: apply(OzMcp.Tasks.EtsStore, :active, args)

  defp default(function, args),
    do: apply(OzMcp.Tasks.Records, function, [OzMcp.Tasks.EtsStore | args])
end
