#
# To add a method:
#   1. Add a row to OzMcp.Method.Table.
#   2. Write the function {Module, fun}/2 that the row names.
#   3. If the method needs a new capability gate, add the atom to
#      OzMcp.Method.gate() and a clause to OzMcp.Method.Capabilities.
#   4. If the method needs a new bind kind, add a clause to OzMcp.Pipeline.Bind.
#   5. If the shape of the params needs a check, add a clause to
#      OzMcp.Validate.JsonRpc.params/1.
#
defmodule OzMcp.Method do
  @moduledoc false

  @enforce_keys [:name, :run]
  defstruct name: nil,
            run: nil,
            gates: [],
            params: :optional,
            bind: :none,
            streaming: false

  @type gate ::
          :tools
          | :prompts
          | :resources
          | :resources_subscribe
          | :logging
          | :completions
          | :tasks
          | :tasks_list
          | :tasks_cancel

  @type bind ::
          :none | :tool | :prompt | :resource | :resource_uri | :completion | :task | :task_list

  @type t :: %__MODULE__{
          name: String.t(),
          run: {module(), atom()},
          gates: [gate()],
          params: :required | :optional,
          bind: bind(),
          streaming: boolean()
        }
end
