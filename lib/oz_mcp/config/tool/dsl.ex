#
# Specs: https://modelcontextprotocol.io/specification/2025-11-25/schema#tool
#
# Helper DSL to configure tools
#
defmodule OzMcp.Config.Tool.DSL do
  @moduledoc """
  Compile-time macros of a tool module (`use OzMcp.Config.Tool`).

  `use OzMcp.Config.Tool` imports the root macro `tool/2` only. The
  nested macros are not imported: they work only inside their `tool`
  block. A nested macro at the root of the module gives a compile
  error (`undefined function title/1`).

  The macros generate `list/0` of the tool behaviour. The
  module must define `call/2`. A module with the DSL cannot define
  `list/0`.

  ## The macros

  | Macro | Block | Value | Wire field |
  |---|---|---|---|
  | `tool "name"` | root | 1 to 128 characters of `A-Za-z0-9_.-`, unique in the module | `name` |
  | `title` | `tool`, `annotations` | non-empty string | `title` |
  | `description` | `tool` | non-empty string | `description` |
  | `required_scopes` | `tool` | list of scope tokens | none (a `403` and a filtered `tools/list`) |
  | `input_schema` | `tool` | JSON Schema map, not empty, with the type `"object"` at the root (the default is `{"type":"object","properties":{}}`) | `inputSchema` |
  | `output_schema` | `tool` | JSON Schema map, not empty, with the type `"object"` at the root | `outputSchema` |
  | `annotations` | `tool` | block | `annotations` |
  | `read_only_hint`, `destructive_hint`, `idempotent_hint`, `open_world_hint` | `annotations` | boolean | `annotations.readOnlyHint` and so on |
  | `execution` | `tool` | block | `execution` |
  | `task_support` | `execution` | `"forbidden"`, `"optional"` or `"required"` | `execution.taskSupport` |
  | `poll_interval` | `execution` | positive integer (ms) | none (the `pollInterval` hint of the task records of the tool) |
  | `immediate_response` | `execution` | non-empty string | none (the `io.modelcontextprotocol/model-immediate-response` text of the `CreateTaskResult`) |
  | `icon` | `tool` (repeatable) | block | one entry of `icons` |
  | `src` | `icon` | `https:` URL, `http:` URL of a loopback host, or `data:` URI | `icons[].src` |
  | `mime_type` | `icon` | non-empty string | `icons[].mimeType` |
  | `sizes` | `icon` | list of `"any"` and `"WxH"` strings | `icons[].sizes` |
  | `theme` | `icon` | `"light"` or `"dark"` | `icons[].theme` |
  | `meta key, value` | `tool` | key: string or atom, value: a JSON term | `_meta.<key>` |

  A wrong value, a macro outside its block, or a property declared two
  times raises at compile time. An `input_schema` and an
  `output_schema` that the JSON Schema validator refuses raise at
  compile time too. With `warn?: true` (the default), a tool with no
  `title` or no `description` gives a compiler warning and a name
  outside the rule of the table gives a compiler warning too (an error
  with `strict_names?: true`).

  The guide [Tools](guides/entities/tools.md) shows an example of the
  DSL.
  """

  alias OzMcp.Config.DSL.{Checks, Rules, Shared}
  alias OzMcp.Structs.{Tool, ToolAnnotations, ToolExecution}

  require OzMcp.Config.DSL.Generate

  @entity %{
    name: :tool,
    struct: Tool,
    key: :name,
    label: "tool name",
    use: "OzMcp.Config.Tool",
    check_name: {__MODULE__, :__check_name__, []}
  }

  @task_support_values "can take only three values: 'forbidden', 'optional' or 'required'"
  @object_schema [:map, :non_empty_map, {:rule, &Rules.object_schema/1}]

  @properties %{
                title: %{
                  paths: [[:tool], [:tool, :annotations]],
                  field: :title,
                  type: :non_empty_string
                },
                input_schema: %{paths: [[:tool]], field: :inputSchema, type: @object_schema},
                output_schema: %{paths: [[:tool]], field: :outputSchema, type: @object_schema},
                read_only_hint: %{
                  paths: [[:tool, :annotations]],
                  field: :readOnlyHint,
                  type: :boolean
                },
                destructive_hint: %{
                  paths: [[:tool, :annotations]],
                  field: :destructiveHint,
                  type: :boolean
                },
                idempotent_hint: %{
                  paths: [[:tool, :annotations]],
                  field: :idempotentHint,
                  type: :boolean
                },
                open_world_hint: %{
                  paths: [[:tool, :annotations]],
                  field: :openWorldHint,
                  type: :boolean
                },
                task_support: %{
                  paths: [[:tool, :execution]],
                  field: :taskSupport,
                  type: [
                    :string,
                    {:one_of, ["forbidden", "optional", "required"], @task_support_values}
                  ]
                },
                poll_interval: %{
                  paths: [[:tool, :execution]],
                  field: :poll_interval,
                  type: {:positive_integer, "a positive integer (ms)"}
                },
                immediate_response: %{
                  paths: [[:tool, :execution]],
                  field: :immediate_response,
                  type: :compact_string
                }
              }
              |> Map.merge(Shared.icon_properties([:tool]))
              |> then(&Map.merge(Shared.entity_properties(:tool), &1))

  @blocks Map.merge(Shared.icon_block([:tool]), %{
            annotations: %{
              paths: [[:tool]],
              field: :annotations,
              initial: ToolAnnotations,
              finish:
                {Checks, :not_empty!,
                 [
                   [:title, :readOnlyHint, :destructiveHint, :idempotentHint, :openWorldHint],
                   "annotations"
                 ]}
            },
            execution: %{
              paths: [[:tool]],
              field: :execution,
              initial: ToolExecution,
              finish: {__MODULE__, :__check_execution__, []}
            }
          })

  @pairs Shared.meta_pair([[:tool]])

  OzMcp.Config.DSL.Generate.macros()

  @doc false
  @spec __check_name__(module(), String.t(), Exception.stacktrace()) :: :ok
  def __check_name__(module, name, stacktrace) do
    case Rules.tool_name(name) do
      :ok ->
        :ok

      {:error, message} ->
        cond do
          Module.get_attribute(module, :__strict_names__) ->
            raise ArgumentError, "tool name #{message}"

          Module.get_attribute(module, :__warn__) ->
            IO.warn(sep986_message(name, message), stacktrace)

          true ->
            :ok
        end
    end
  end

  @doc false
  @spec __check_execution__(ToolExecution.t()) :: ToolExecution.t()
  def __check_execution__(data) do
    no_task = is_nil(data.taskSupport) or data.taskSupport == "forbidden"

    if not is_nil(data.poll_interval) and no_task do
      raise "a tool with a 'poll_interval' needs a 'task_support' with the value 'optional' or 'required'"
    end

    if not is_nil(data.immediate_response) and no_task do
      raise "a tool with an 'immediate_response' needs a 'task_support' with the value 'optional' or 'required'"
    end

    data
  end

  defp sep986_message(name, message) do
    """
    The tool name #{inspect(name)} does not follow the MCP recommendation (SEP-986)

    - #{message}
    - Some clients can refuse or change this tool.

    To enforce the rule: use OzMcp.Config.Tool, strict_names?: true
    To disable warnings: use OzMcp.Config.Tool, warn?: false
    """
  end
end
