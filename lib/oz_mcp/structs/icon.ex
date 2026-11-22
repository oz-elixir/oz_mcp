defmodule OzMcp.Structs.Icon do
  @moduledoc """
  Helper module used to build `Icon` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %Icon{}
    |> Icon.src("https://img.com/icon.png")
    |> Icon.mime_type("image/png")
    |> Icon.sizes(["16x16"])
    |> Icon.theme(:dark)
    |> Icon.build()
  ```

  Result:

  ```elixir
  %{
    mimeType: "image/png",
    theme: :dark,
    src: "https://img.com/icon.png",
    sizes: ["16x16"]
  }
  ```

  Specification: [Icon](https://modelcontextprotocol.io/specification/2025-11-25/schema#icon)
  """

  use OzMcp.Structs.Wire,
    fields: [
      src: {:string, required: true, also: :icon_src},
      mimeType: :string,
      sizes: {:list, also: :icon_sizes_or_nil},
      theme: {:any, check: :validate_theme, type: quote(do: theme())}
    ]

  alias OzMcp.Structs.Validate

  @type theme :: :light | :dark | nil

  @doc false
  @spec check(t()) :: :ok
  def check(%__MODULE__{} = struct) do
    Validate.non_empty_string(:src, struct.src)
    Validate.icon_src(:src, struct.src)
    Validate.non_empty_string_or_nil(:mimeType, struct.mimeType)
    Validate.list_or_nil(:sizes, struct.sizes)
    Validate.icon_sizes_or_nil(:sizes, struct.sizes)
    validate_theme(struct.theme)
  end

  @spec validate_theme(term()) :: :ok
  defp validate_theme(nil), do: :ok

  defp validate_theme(value) do
    if value in [:light, :dark, "light", "dark"] do
      :ok
    else
      raise ArgumentError,
            "'theme' must be :light, :dark, \"light\", or \"dark\", got: #{inspect(value)}"
    end
  end
end
