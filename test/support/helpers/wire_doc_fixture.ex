#
# The fixture of the generated moduledoc: it keeps its `@moduledoc`,
# because the test of `OzMcp.Structs.Wire` reads it.
#
defmodule Support.Helpers.WireDocFixture do
  @moduledoc "A fixture."

  use OzMcp.Structs.Wire,
    fields: [
      id: {:string, required: true},
      mimeType: :string,
      icons: {:list_of, OzMcp.Structs.Icon},
      status: {{:one_of, [:on, :off]}, required: true, default: :on},
      hidden: {:any, emit: :never},
      _meta: :meta
    ]
end
