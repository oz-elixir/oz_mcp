#
# Helper DSL to configure templates
#
defmodule OzMcp.Config.Template.DSL do
  @moduledoc """
  Compile-time macros of a resource template module (`use
  OzMcp.Config.Template`).

  `use OzMcp.Config.Template` imports the root macro `template/2`
  only. The nested macros are not imported: they work only inside
  their `template` block. A nested macro at the root of the module
  gives a compile error (`undefined function uri_template/1`).

  The macros generate `list/0` of the template behaviour.
  The module must define `read/4`. A module with the DSL cannot define
  `list/0`. The compiled matcher of each
  template matches the requested uri in the order of the module and
  gives `{template, uri_params}`.

  ## The macros

  | Macro | Block | Value | Wire field |
  |---|---|---|---|
  | `template "name"` | root | non-empty string | `name` |
  | `uri_template` | `template` | non-empty string, unique in the module, a valid URI template of RFC 6570 | `uriTemplate` |
  | `title` | `template` | non-empty string | `title` |
  | `description` | `template` | non-empty string | `description` |
  | `mime_type` | `template`, `icon` | non-empty string | `mimeType` |
  | `required_scopes` | `template` | list of scope tokens | none (a `403` and a filtered `resources/templates/list`) |
  | `annotations` | `template` | block | `annotations` |
  | `audience` | `annotations` | list of `"user"` and `"assistant"` | `annotations.audience` |
  | `priority` | `annotations` | number from 0 to 1 | `annotations.priority` |
  | `last_modified` | `annotations` | ISO 8601 date and time with an offset, for example `2025-01-12T15:00:58Z` | `annotations.lastModified` |
  | `icon` | `template` (repeatable) | block | one entry of `icons` |
  | `src` | `icon` | `https:` URL, `http:` URL of a loopback host, or `data:` URI | `icons[].src` |
  | `sizes` | `icon` | list of `"any"` and `"WxH"` strings | `icons[].sizes` |
  | `theme` | `icon` | `"light"` or `"dark"` | `icons[].theme` |
  | `meta key, value` | `template` | key: string or atom, value: a JSON term | `_meta.<key>` |

  A wrong value, a macro outside its block, or a property declared two
  times raises at compile time. The `template` block requires a
  `uri_template`. With `warn?: true` (the default), a template with no
  `title` or no `description` gives a compiler warning.

  The DSL checks each `uri_template` at compile time with
  OzMcp.Utils.TemplateUri. The template must be a valid URI template
  of RFC 6570, levels 1 to 3 (`{var}`, `{+var}`, `{#var}`, `{.var}`,
  `{/var}`, `{;var}`, `{?var}`, `{&var}` and the lists `{a,b}`). A bad
  template raises with the fault and its position and a level 4
  modifier (`{a*}`, `{a:3}`) raises too. Two templates of one module
  whose `uri_template` strings differ only in the names of their
  variables (the same shape, for example `file:///{a}` and
  `file:///{b}`) raise too: the first one would hide the second one.
  The compiled matcher of each template is built at compile time: no
  parse and no cache at request time.

  The guide [Templates](guides/entities/templates.md) shows an example
  of the DSL.
  """

  alias OzMcp.Config.DSL.{Checks, Shared}
  alias OzMcp.Structs.ResourceTemplate
  alias OzMcp.Utils.TemplateUri

  require OzMcp.Config.DSL.Generate

  @entity %{
    name: :template,
    struct: ResourceTemplate,
    key: :uriTemplate,
    label: "template uri_template",
    use: "OzMcp.Config.Template",
    finish: {__MODULE__, :__compile_uri__, []},
    accepted: {__MODULE__, :__check_shape__, []}
  }

  @properties Map.merge(Shared.resource_properties(:template), %{
                uri_template: %{
                  paths: [[:template]],
                  field: :uriTemplate,
                  type: :non_empty_string
                }
              })

  @blocks Shared.resource_blocks(:template)
  @pairs Shared.meta_pair([[:template]])

  OzMcp.Config.DSL.Generate.macros()

  @doc false
  @spec __compile_uri__(ResourceTemplate.t(), module()) :: :ok
  def __compile_uri__(data, module) do
    Checks.required!(data, module, :uriTemplate, "template 'uri_template' is required")

    case TemplateUri.compile(data.uriTemplate) do
      {:ok, compiled} ->
        previous = Module.get_attribute(module, :__compiled__)
        Module.put_attribute(module, :__compiled__, previous ++ [compiled])

      {:error, message} ->
        raise ArgumentError,
              "template \"#{data.name}\": invalid URI template " <>
                "#{inspect(data.uriTemplate)}: " <> message
    end
  end

  @doc false
  @spec __check_shape__(ResourceTemplate.t(), module()) :: :ok
  def __check_shape__(data, module) do
    compiled = Module.get_attribute(module, :__compiled__)
    current = List.last(compiled)

    case Enum.find(Enum.drop(compiled, -1), &(&1.shape == current.shape)) do
      nil ->
        :ok

      other ->
        raise ArgumentError,
              "duplicate template uri_template shape: #{inspect(data.uriTemplate)} " <>
                "has the same shape as #{inspect(other.template)}"
    end
  end
end
