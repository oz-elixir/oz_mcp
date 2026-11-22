defmodule OzMcp.Structs.NotificationParams do
  @moduledoc """
  Helper module used to build `NotificationParams` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %NotificationParams{}
    |> NotificationParams._meta(%{"progressToken" => 42})
    |> NotificationParams.build()
  ```

  Result:

  ```elixir
  %{"_meta" => %{"progressToken" => 42}}
  ```

  Specification: no definition in specification 2025-11-25.
  """

  use OzMcp.Structs.Wire,
    build: false,
    fields: [_meta: :meta]

  alias OzMcp.Structs.Validate

  @spec build(t()) :: map()
  def build(struct) do
    Validate.meta(:_meta, struct._meta)

    if is_nil(struct._meta) or struct._meta == %{} do
      raise ArgumentError, "Meta fields is not defined, remove params declaration"
    end

    %{"_meta" => struct._meta}
  end
end
