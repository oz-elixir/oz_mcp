defmodule OzMcp.Structs.EmbeddedResource do
  @moduledoc """
  Helper module used to build `EmbeddedResource` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %EmbeddedResource{}
    |> EmbeddedResource.resource(
      %TextResourceContents{}
      |> TextResourceContents.uri("file:///logs/app.log")
      |> TextResourceContents.text("INFO App started")
    )
    |> EmbeddedResource.build()
  ```

  Result:

  ```elixir
  %{
    type: "resource",
    resource: %{text: "INFO App started", uri: "file:///logs/app.log"}
  }
  ```

  ## Long example:

  ```elixir
  %EmbeddedResource{}
    |> EmbeddedResource.resource(
      %BlobResourceContents{}
      |> BlobResourceContents.uri("file:///assets/logo.png")
      |> BlobResourceContents.blob("iVBORw0KGgoAAAANSUhEUg==")
      |> BlobResourceContents.mime_type("image/png")
    )
    |> EmbeddedResource.annotations(
      %Annotations{}
      |> Annotations.audience(["assistant"])
    )
    |> EmbeddedResource._meta(%{"key" => "value"})
    |> EmbeddedResource.build()
  ```

  Result:

  ```elixir
  %{
    type: "resource",
    resource: %{
      uri: "file:///assets/logo.png",
      blob: "iVBORw0KGgoAAAANSUhEUg==",
      mimeType: "image/png"
    },
    annotations: %{audience: ["assistant"]},
    _meta: %{"key" => "value"}
  }
  ```

  Specification: [EmbeddedResource](https://modelcontextprotocol.io/specification/2025-11-25/schema#embeddedresource)
  """

  use OzMcp.Structs.Wire,
    build: false,
    const: %{type: "resource"},
    fields: [
      resource:
        {:any, default: %OzMcp.Structs.TextResourceContents{}, type: quote(do: resource())},
      annotations: {:struct, OzMcp.Structs.Annotations},
      _meta: :meta
    ]

  alias OzMcp.Structs.{Annotations, BlobResourceContents, ResourceContents, TextResourceContents}
  alias OzMcp.Structs.{Builder, Keys, Validate}

  @type resource :: ResourceContents.t()

  @spec build(t()) :: map()
  def build(struct) do
    validate_resource(struct.resource)
    Validate.meta(:_meta, struct._meta)
    Validate.struct_or_nil(:annotations, Annotations, struct.annotations)

    %{type: "resource"}
    |> put_resource(struct)
    |> Builder.maybe_annotations(struct)
    |> Builder.maybe_meta(struct)
  end

  defp validate_resource(nil) do
    raise ArgumentError, "The 'resource' field is required"
  end

  defp validate_resource(%TextResourceContents{}), do: :ok
  defp validate_resource(%BlobResourceContents{}), do: :ok

  defp validate_resource(%{} = value),
    do: Validate.resource_contents(value, "a 'resource' map")

  defp validate_resource(value) do
    raise ArgumentError,
          "The 'resource' field must be a %TextResourceContents{} or " <>
            "%BlobResourceContents{} struct or a map(), got: #{inspect(value)}"
  end

  defp put_resource(result, struct) do
    built =
      case struct.resource do
        c when is_struct(c, TextResourceContents) -> TextResourceContents.build(c)
        c when is_struct(c, BlobResourceContents) -> BlobResourceContents.build(c)
        c -> c
      end

    Map.put(result, :resource, built)
  end

  # The struct default fills the resource the block misses, so a present nil stays an error.
  #
  @doc false
  @spec check_map(map()) :: :ok
  def check_map(block) do
    check_resource(Keys.get(block, "resource", :resource, %TextResourceContents{}))
    Validate.meta(:_meta, Keys.get(block, "_meta", :_meta, nil))
    Validate.annotations(Keys.get(block, "annotations", :annotations, nil))
  end

  defp check_resource(nil), do: raise(ArgumentError, "The 'resource' field is required")

  defp check_resource(%TextResourceContents{} = item), do: TextResourceContents.check(item)
  defp check_resource(%BlobResourceContents{} = item), do: BlobResourceContents.check(item)

  defp check_resource(%{__struct__: other}) do
    raise(
      ArgumentError,
      "resource must be a map, a OzMcp.Structs.TextResourceContents or " <>
        "a OzMcp.Structs.BlobResourceContents, got: #{inspect(other)}"
    )
  end

  defp check_resource(%{} = item), do: Validate.resource_contents(item, "a 'resource' map")

  defp check_resource(value) do
    raise(
      ArgumentError,
      "resource must be a map, a OzMcp.Structs.TextResourceContents or " <>
        "a OzMcp.Structs.BlobResourceContents, got: #{inspect(value)}"
    )
  end
end
