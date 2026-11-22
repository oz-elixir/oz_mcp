defmodule OzMcp.Structs.ToolChoice do
  @moduledoc """
  Helper module used to build `ToolChoice` structure: how the model uses the
  tools of a sampling request.

  _(MCP protocol: 2025-11-25)_

  The mode is `:auto` (the model decides, the default of the client),
  `:required` (the model must call a tool) or `:none` (the model must not).

  ## Short example:

  ```elixir
  %ToolChoice{} |> ToolChoice.mode(:required) |> ToolChoice.build()
  ```

  Result:

  ```elixir
  %{mode: "required"}
  ```

  Specification: [ToolChoice](https://modelcontextprotocol.io/specification/2025-11-25/schema#toolchoice)
  """

  use OzMcp.Structs.Wire,
    build: false,
    fields: [
      mode: {:any, type: quote(do: mode() | String.t() | nil)}
    ]

  alias OzMcp.Structs.Validate

  @modes [:auto, :required, :none, "auto", "required", "none"]

  @type mode :: :auto | :required | :none

  @spec build(t()) :: map()
  def build(struct) do
    Validate.one_of_or_nil(:mode, struct.mode, @modes)

    case struct.mode do
      nil -> %{}
      mode -> %{mode: to_string(mode)}
    end
  end
end
