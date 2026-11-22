#
# Specs: https://modelcontextprotocol.io/specification/2025-11-25/schema#prompt
#
# Helper DSL to configure prompts
#
defmodule OzMcp.Config.Prompt.DSL do
  @moduledoc """
  Compile-time macros of a prompt module (`use OzMcp.Config.Prompt`).

  `use OzMcp.Config.Prompt` imports the root macro `prompt/2` only.
  The nested macros are not imported: they work only inside their
  `prompt` block. A nested macro at the root of the module gives a
  compile error (`undefined function argument/2`).

  The macros generate `list/0` of the prompt behaviour.
  The module must define `get/2`. A module with the DSL cannot define
  `list/0`.

  ## The macros

  | Macro | Block | Value | Wire field |
  |---|---|---|---|
  | `prompt "name"` | root | non-empty string, unique in the module | `name` |
  | `title` | `prompt` | non-empty string | `title` |
  | `description` | `prompt` | non-empty string | `description` |
  | `required_scopes` | `prompt` | list of scope tokens | none (a `403` and a filtered `prompts/list`) |
  | `argument "name"` | `prompt` (repeatable) | name: non-empty string, unique in the prompt | one entry of `arguments` |
  | `argument "name", opts` | `prompt` (repeatable) | `title:` and `description:` are non-empty strings, `required:` is a boolean | `arguments[].title`, `.description`, `.required` |
  | `icon` | `prompt` (repeatable) | block | one entry of `icons` |
  | `src` | `icon` | `https:` URL, `http:` URL of a loopback host, or `data:` URI | `icons[].src` |
  | `mime_type` | `icon` | non-empty string | `icons[].mimeType` |
  | `sizes` | `icon` | list of `"any"` and `"WxH"` strings | `icons[].sizes` |
  | `theme` | `icon` | `"light"` or `"dark"` | `icons[].theme` |
  | `meta key, value` | `prompt` | key: string or atom, value: a JSON term | `_meta.<key>` |

  The framework sends `required` on the wire only when it is `true`.
  An option that is not `title`, `description` or `required` raises at
  compile time. A wrong value, a macro outside its block, or a
  property declared two times raises at compile time too. With
  `warn?: true` (the default), a prompt with no `title` or no
  `description` gives a compiler warning.

  The guide [Prompts](guides/entities/prompts.md) shows an example of
  the DSL.
  """

  alias OzMcp.Config.DSL.{Core, Shared}
  alias OzMcp.Structs.{Prompt, PromptArgument}

  require OzMcp.Config.DSL.Generate

  @entity %{
    name: :prompt,
    struct: Prompt,
    key: :name,
    label: "prompt name",
    use: "OzMcp.Config.Prompt"
  }

  @properties Map.merge(
                Shared.entity_properties(:prompt),
                Shared.icon_properties([:prompt])
              )

  @blocks Shared.icon_block([:prompt])
  @pairs Shared.meta_pair([[:prompt]])
  @extra_qualify [argument: 1, argument: 2]

  OzMcp.Config.DSL.Generate.macros()

  # `argument` has its own form and its own messages.
  #
  defmacro argument(name, opts \\ []) do
    quote do
      OzMcp.Config.Prompt.DSL.__argument__(__MODULE__, unquote(name), unquote(opts))
    end
  end

  @doc false
  @spec __argument__(module(), term(), term()) :: :ok
  def __argument__(module, name, opts) do
    check_argument_name!(name)
    check_argument_opts!(opts)

    argument = %PromptArgument{
      name: name,
      title: Keyword.get(opts, :title),
      description: Keyword.get(opts, :description),
      required: Keyword.get(opts, :required)
    }

    Core.update(module, :argument, [[:prompt]], fn data ->
      arguments = data.arguments || []

      if Enum.any?(arguments, &(&1.name == name)) do
        raise "argument '#{name}' already exists"
      end

      Map.put(data, :arguments, arguments ++ [argument])
    end)
  end

  defp check_argument_name!(name) do
    if not is_binary(name) do
      raise ArgumentError, "name must be a string, got: #{inspect(name)}"
    end

    if name == "" do
      raise ArgumentError, "'name' cannot be an empty string"
    end

    :ok
  end

  defp check_argument_opts!(opts) do
    if not is_list(opts) do
      raise ArgumentError, "'opts' must be a keyword list, got: #{inspect(opts)}"
    end

    unknown_keys = Keyword.keys(opts) -- [:title, :description, :required]

    if unknown_keys != [] do
      raise ArgumentError,
            "unknown argument option(s): #{inspect(unknown_keys)}, " <>
              "allowed options are :title, :description and :required"
    end

    title = Keyword.get(opts, :title)
    description = Keyword.get(opts, :description)
    required = Keyword.get(opts, :required)

    if not is_nil(title) and (not is_binary(title) or title == "") do
      raise ArgumentError, "'title' must be a non-empty string, got: #{inspect(title)}"
    end

    if not is_nil(description) and (not is_binary(description) or description == "") do
      raise ArgumentError,
            "'description' must be a non-empty string, got: #{inspect(description)}"
    end

    if not is_nil(required) and not is_boolean(required) do
      raise ArgumentError, "'required' must be a boolean, got: #{inspect(required)}"
    end

    :ok
  end
end
