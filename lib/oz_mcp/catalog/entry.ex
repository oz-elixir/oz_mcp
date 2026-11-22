#
# One entity of a static module: key (name, uri or uriTemplate), the
# normalized struct, the built map of that struct and the compiled
# matcher of a template.
#
defmodule OzMcp.Catalog.Entry do
  @moduledoc false

  @enforce_keys [:key, :entity]
  defstruct [:key, :entity, :wire, :matcher]

  @type t :: %__MODULE__{}
end
