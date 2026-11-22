#
# Specs: https://modelcontextprotocol.io/specification/2025-11-25/schema#resource
#
# Helper DSL to configure resources
#
defmodule OzMcp.Config.Resource.DSL do
  @moduledoc """
  Compile-time macros of a resource module (`use OzMcp.Config.Resource`).

  `use OzMcp.Config.Resource` imports the root macro `resource/2`
  only. The nested macros are not imported: they work only inside
  their `resource` block. A nested macro at the root of the module
  gives a compile error (`undefined function uri/1`).

  The macros generate `list/0` of the resource behaviour.
  The module must define `read/2`. A module with the DSL cannot define
  `list/0`.

  ## The macros

  | Macro | Block | Value | Wire field |
  |---|---|---|---|
  | `resource "name"` | root | non-empty string | `name` |
  | `uri` | `resource` | absolute URI with a scheme, unique in the module | `uri` |
  | `title` | `resource` | non-empty string | `title` |
  | `description` | `resource` | non-empty string | `description` |
  | `mime_type` | `resource`, `icon` | non-empty string | `mimeType` |
  | `size` | `resource` | integer of 1 or more (bytes) | `size` |
  | `required_scopes` | `resource` | list of scope tokens | none (a `403` and a filtered `resources/list`) |
  | `annotations` | `resource` | block | `annotations` |
  | `audience` | `annotations` | list of `"user"` and `"assistant"` | `annotations.audience` |
  | `priority` | `annotations` | number from 0 to 1 | `annotations.priority` |
  | `last_modified` | `annotations` | ISO 8601 date and time with an offset, for example `2025-01-12T15:00:58Z` | `annotations.lastModified` |
  | `icon` | `resource` (repeatable) | block | one entry of `icons` |
  | `src` | `icon` | `https:` URL, `http:` URL of a loopback host, or `data:` URI | `icons[].src` |
  | `sizes` | `icon` | list of `"any"` and `"WxH"` strings | `icons[].sizes` |
  | `theme` | `icon` | `"light"` or `"dark"` | `icons[].theme` |
  | `meta key, value` | `resource` | key: string or atom, value: a JSON term | `_meta.<key>` |

  A wrong value, a macro outside its block, or a property declared two
  times raises at compile time. The `resource` block requires a `uri`.
  With `warn?: true` (the default), a resource with no `title` or no
  `description` gives a compiler warning.

  The guide [Resources](guides/entities/resources.md) shows an example
  of the DSL.
  """

  alias OzMcp.Config.DSL.{Checks, Rules, Shared}
  alias OzMcp.Structs.Resource

  require OzMcp.Config.DSL.Generate

  @entity %{
    name: :resource,
    struct: Resource,
    key: :uri,
    label: "resource uri",
    use: "OzMcp.Config.Resource",
    finish: {Checks, :required!, [:uri, "resource 'uri' is required"]}
  }

  @properties Map.merge(Shared.resource_properties(:resource), %{
                uri: %{
                  paths: [[:resource]],
                  field: :uri,
                  type: [:non_empty_string, {:rule, &Rules.absolute_uri/1}]
                },
                size: %{
                  paths: [[:resource]],
                  field: :size,
                  type: {:rule, &Rules.resource_size/1}
                }
              })

  @blocks Shared.resource_blocks(:resource)
  @pairs Shared.meta_pair([[:resource]])

  OzMcp.Config.DSL.Generate.macros()
end
