defmodule OzMcp.Pipeline.Bound do
  @moduledoc """
  The entity of a request, found by the bind stage of the pipeline
  (OzMcp.Pipeline.Bind). The stage puts the struct in the field
  `bound` of the context and the `authorize/3` callback of a verifier
  receives it as its third argument.

  `kind` is the kind of the entity the request names:

    * `:tool` for `tools/call`: `name` is the tool name, `module` the
      tool module and `entity` the tool configuration. `arguments`
      holds the arguments (with the defaults of the input schema
      applied), `input_errors` the messages of a schema violation and
      `task` the metadata of a task-augmented call.
    * `:resource` or `:template` for `resources/read` and `resources/subscribe`:
      `name` is the uri, `uri_params` the values of the template variables.
    * `:prompt` for `prompts/get`: `arguments` holds the arguments of
      the request.
    * `:completion` for `completion/complete`: `completion` holds the
      reference, the argument and the context of the completion.
    * `:task` for `tasks/get`, `tasks/list`, `tasks/cancel` and
      `tasks/result`: `name` is the task id when the method carries one.
    * `:none` for every other method: `params` holds the params of the
      request.

  The bound entity of a kind that names an entity carries the
  `required_scopes` of the entity, whatever form the module gave (the
  catalog stores a struct) and `params` holds the params of the request
  as the bind stage received or adjusted them.
  """

  @type kind :: :tool | :resource | :template | :prompt | :completion | :task | :none

  @type t :: %__MODULE__{
          kind: kind(),
          name: String.t() | nil,
          module: module() | nil,
          entity: struct() | nil,
          params: map(),
          arguments: map(),
          uri_params: map() | nil,
          input_errors: [String.t()] | nil,
          required_scopes: [String.t()],
          task: %{ttl: non_neg_integer() | nil} | nil,
          completion: map() | nil
        }

  @enforce_keys [:kind]
  defstruct kind: nil,
            name: nil,
            module: nil,
            entity: nil,
            params: %{},
            arguments: %{},
            uri_params: nil,
            input_errors: nil,
            required_scopes: [],
            task: nil,
            completion: nil
end
