# Entity modules

A server gives four kinds of entity to the client: tools, resources,
resource templates and prompts. Each kind has its own module with its own
`use` line. The four kinds work in the same way. They have the same two
ways to declare a module, the same rules for a list, the same rules for
the result of a callback and the same rules for the registration in a
server. This guide gives these shared rules one time. The guide of each
kind gives what belongs to the kind only.

The completions are not a kind of entity. A prompt module or a template
module can add them. See [Completions](completions.md).

## The four kinds

| Kind | `use` | Callback | Struct | Unique key | Wire keys |
|---|---|---|---|---|---|
| Tool | `use OzMcp.Config.Tool` | `call/2` | `%OzMcp.Structs.Tool{}` | `name` | `name`, `inputSchema`, ... |
| Resource | `use OzMcp.Config.Resource` | `read/2` | `%OzMcp.Structs.Resource{}` | `uri` | `uri`, `name`, ... |
| Template | `use OzMcp.Config.Template` | `read/4` | `%OzMcp.Structs.ResourceTemplate{}` | `uri_template` (`uriTemplate` on the wire) | `uriTemplate`, `name`, ... |
| Prompt | `use OzMcp.Config.Prompt` | `get/2` | `%OzMcp.Structs.Prompt{}` | `name` | `name`, `arguments`, ... |

The guides [Tools](tools.md), [Resources](resources.md),
[Templates](templates.md) and [Prompts](prompts.md) describe each kind.

## The two ways

Each entity module uses one of the two ways of this table. The table
shows the tool module. The other kinds replace `Tool` and `call/2` with
the names of their row in the table of the kinds:

| Way | `use` | What you write | What the framework generates |
|---|---|---|---|
| DSL | `use OzMcp.Config.Tool` | one block for each entity and the callback | `list/0`. The DSL checks the values at compile time. |
| Data | `use OzMcp.Config.Tool, dsl?: false` | `list/0` that returns structs or maps with the wire keys and the callback | nothing |

An option that the `use` line of an entity module does not know stops the
compilation. The error names the option.

### The `use` options

| Option | Default | Effect |
|---|---|---|
| `dsl?:` | `true` | `false` removes the DSL. You write `list/0` yourself (the data way) |
| `warn?:` | `true` | a compiler warning for an entity without a `title` or a `description` (and, for a tool, the warnings of tool names and of task support). `false` removes the warnings |

Rules for the way with `dsl?: false`:

  * A map carries `required_scopes` like a struct: the boot of the
    instance reads the key, checks it and it never reaches the client.

The server reads each module one time, at the boot of the instance and
answers a lookup and a list from the catalog. A change of a module needs
a stop and a start of the instance: a `recompile` in `iex -S mix` does
not change the catalog. A restart of the supervisor of the instance
keeps the catalog of the previous start. The boot checks the names of
the modules: two modules of one server that declare the same unique key
stop the boot.

## Way 1: the DSL

A block for each entity declares it and the framework generates
`list/0` from the blocks. The DSL checks the values at compile time.

One tool with the DSL:

```elixir
defmodule MyApp.Overview.DslTool do
  use OzMcp.Config.Tool

  tool "echo" do
    title "Echo"
    description "Answers ok"
    input_schema %{type: "object"}
  end

  @impl true
  def call(_ctx, _params), do: {:ok, %{content: [%{type: "text", text: "ok"}]}}
end
```

The guide of each kind gives the macros of its block.

## Way 2: the entries of `list/0`

An entry is a struct or a map with the wire keys. The two forms give the
same list entry and the same lookup. The framework turns each entry into
a struct one time and `build/1` of the struct checks the whole entity.

The two examples below declare the same tool.

The struct form:

```elixir
defmodule MyApp.Overview.StructEntryTool do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.Tool

  @impl true
  def list do
    [%Tool{} |> Tool.name("echo") |> Tool.input_schema(%{type: "object"})]
  end

  @impl true
  def call(_ctx, _params), do: {:ok, %{content: [%{type: "text", text: "ok"}]}}
end
```

The map form:

```elixir
defmodule MyApp.Overview.MapEntryTool do
  use OzMcp.Config.Tool, dsl?: false

  @tools [%{name: "echo", inputSchema: %{type: "object"}}]

  @impl true
  def list, do: @tools

  @impl true
  def call(_ctx, _params), do: {:ok, %{content: [%{type: "text", text: "ok"}]}}
end
```

The server pages the list itself: `list/0` returns every entry.

The normalizer applies the same rules to the two forms:

  * An unknown top-level key of a map goes to the `extras` field of the
    struct. A key of the struct wins over an extra with the same name
    and the extra goes to the client in the list.
  * A nested unknown key is an error that names the path. A custom value
    goes in `_meta`. The guide of each kind gives its nested fields that
    the framework checks.
  * A map carries `required_scopes` like the field of the struct. The
    framework checks the scopes and the key never reaches the client.
  * An entry must be JSON. A term that is not JSON (a tuple, a PID, a
    struct such as `URI`, a string that is not valid UTF-8) stops the
    boot and the error names the module, the kind and the path, for
    example `the entry is not JSON at _meta.ref`.

The boot always checks the entries: the runtime option `check_results`
applies to the results of the callbacks only.

## The result of a callback: struct or map

The callback of each kind returns `{:ok, result}`. The `result` is the
result struct of the method, or a map with the wire keys:

| Kind | Callback | Result struct | Required member |
|---|---|---|---|
| Tool | `call/2` | `%OzMcp.Structs.CallToolResult{}` | `content` |
| Resource | `read/2` | `%OzMcp.Structs.ReadResourceResult{}` | `contents` |
| Template | `read/4` | `%OzMcp.Structs.ReadResourceResult{}` | `contents` |
| Prompt | `get/2` | `%OzMcp.Structs.GetPromptResult{}` | `messages` |

The struct form and the map form of one tool result:

```elixir
alias OzMcp.Structs.{CallToolResult, TextContent}

{:ok,
 %CallToolResult{}
 |> CallToolResult.content([%TextContent{} |> TextContent.text("ok")])
 |> CallToolResult.is_error(false)}

{:ok, %{content: [%{type: "text", text: "ok"}], isError: false}}
```

The two forms give the same answer to the client.

### The same check for the two forms

With the runtime option `check_results: true` (the default), the
framework builds a map result into its result struct first. A map and a
struct then get the same check:

  * The `build/1` of the struct checks each field: a required member is
    present and not empty, a field has the right type, each content
    block or contents item follows the rules of its struct and the keys
    of `_meta` follow the format of the specification.
  * A map result with no required member, or with a member set to `nil`,
    fails the check.
  * The built answer must be JSON: no struct inside, no string that is
    not valid UTF-8, no key that is an atom and a string.

A result that fails the check gives the client the error `-32603` and
the server log an error that names the problem. The callback does not
crash the session.

So the struct form does not give more checks at run time. It helps when
you write the code:

  * A setter names a field of the specification. A wrong name gives a
    compiler warning: `CallToolResult.is_eror/2` does not exist. In a
    map, a wrong key (`is_error:` for `isError:`) is not an error: it
    goes to the client as an extra key and the check does not see it.
  * The struct modules have typespecs, so Dialyzer can check the values.

The extra keys of the map form and the `extras` field of the struct
form follow the same rule: a member of the specification wins over an
extra with the same name.

### The option `check_results: false`

With `check_results: false`, the two forms are not the same:

  * A map result goes to the client as it is. The framework does not
    build it into a struct and does not check it.
  * A struct result still runs its `build/1`, so the field checks stay
    on. A bad struct still gives the error `-32603`.
  * A result that is not JSON, in the two forms, gives the error
    `-32603` when the framework encodes the answer.

The map form with `check_results: false` is the path with the least
work. The gain is small next to the work of the callback and the JSON
encoding: measure it with your own results before you turn the check
off. The option applies to every callback of the instance, not to one
module. A wrong map (a missing `content`, a key with a typo, a bad
`_meta` key) then reaches the client with no error and the client
must deal with it.

The error path of a callback (an `{:error, ...}` answer, a raise, a
deadline overrun) keeps its checks with the two values. The option
`check_output_schemas` is a separate option for the `structuredContent`
of a tool. See the guide about the runtime options.

## Icons and `_meta`

The four kinds have the `icon` block and the `meta` macro. The rules of
`src`, `sizes`, `theme` and the key of `meta` are in the table of
[Validation rules](../servers/declare_a_server.md#validation-rules). Two
more facts apply to an entity:

  * Each macro accepts its value one time in its block. A value that you
    declare two times stops the compilation.
  * The build of an entity struct (Way 2) refuses the same values as
    the DSL: an `Icon` with a wrong `src` or `sizes` and a `meta` key
    outside the rules.

## Register the module in a server

List the module in the block of its kind in the server module: `tools`,
`resources`, `templates` or `prompts`. List each module one time. The
block gives the capability and `paginate` gives the size of a page. See
[The registry blocks](../servers/declare_a_server.md#the-registry-blocks).

## Common mistakes

  * A list that changes in a module. The list methods and the lookups
    show the entries of the boot. A stop and a start of the instance
    reads the new list.
