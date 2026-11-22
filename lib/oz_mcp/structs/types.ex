defmodule OzMcp.Structs.Types do
  @moduledoc """
  Helper module used to define shared types for the `OzMcp.Structs` modules.
  """

  @type list_of(t) :: list(t | map()) | []
end
