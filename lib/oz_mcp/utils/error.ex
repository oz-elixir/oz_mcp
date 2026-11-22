defmodule OzMcp.Utils.Error do
  @moduledoc """
  A JSON-RPC error that a callback returns.

  The struct has three fields: `code` (an integer), `message` (a
  string) and `data` (a map or a list, or `nil`). The framework puts
  the fields in the `error` object of the JSON-RPC response. The client
  receives the `code`, the `message` and the `data` as they are.

  ## When to return an error struct

  Return `{:error, %OzMcp.Utils.Error{}}` for a protocol error: the
  entity does not exist, or the request does not agree with the
  protocol. The framework answers an unknown entity itself.

  | Helper | Code | Use |
  |---|---|---|
  | `invalid_params/2` | `-32602` | an invalid argument |
  | `resource_not_found/1` | `-32002` | a resource uri whose data does not exist |
  | `internal_error/2` | `-32603` | a failure of the callback that has no better code |
  | `new/3` | any | another code |

  A tool callback that returns the error struct sends the failure as a
  JSON-RPC error: the model does not read it. A task-augmented call
  that gets an error struct makes the task `failed`.

  ## When to return a tool error result

  In a tool callback, return `{:ok, result}` with `isError: true` when
  the work of the tool failed and the model can correct the input. The
  model reads the `content` of the result:

      {:ok,
       %CallToolResult{}
       |> CallToolResult.content([
         %TextContent{} |> TextContent.text("The city is unknown")
       ])
       |> CallToolResult.is_error(true)
       |> CallToolResult.build()}

  The `read/2`, `read/4` and `get/2` callbacks have no tool error
  result: they return the error struct for each failure.
  """

  @type t() :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: map() | list() | nil
        }

  defstruct code: 0,
            message: "",
            data: nil

  @doc """
  Builds an error struct with a `code`, a `message` and an optional
  `data`. The `data` is a map or a list of JSON terms, or `nil`.
  """
  @spec new(integer(), String.t(), map() | list() | nil) :: %__MODULE__{}
  def new(code, message, data \\ nil) do
    %__MODULE__{
      code: code,
      message: message,
      data: data
    }
  end

  @doc "Builds the error `-32602`: the `message` names the invalid argument."
  @spec invalid_params(String.t(), map() | list() | nil) :: %__MODULE__{}
  def invalid_params(message, data \\ nil) when is_binary(message),
    do: new(-32602, message, data)

  @doc ~S'Builds the error `-32002` with the data `%{"uri" => uri}`.'
  @spec resource_not_found(String.t()) :: %__MODULE__{}
  def resource_not_found(uri) when is_binary(uri),
    do: new(-32002, "resource not found", %{"uri" => uri})

  @doc "Builds the error `-32603`. The client reads the `message`: keep the details out."
  @spec internal_error(String.t(), map() | list() | nil) :: %__MODULE__{}
  def internal_error(message \\ "internal error", data \\ nil) when is_binary(message),
    do: new(-32603, message, data)
end
