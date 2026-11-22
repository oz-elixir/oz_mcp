# Prompts

This guide describes each way to declare a prompt module and each
option of the prompt DSL. A prompt is a template of messages that the
user of the client selects. The introduction guide shows a first tool
and a first server.

## What a prompt is

A prompt is a template of messages that the user selects in the
client. The methods `prompts/list` and `prompts/get` use the prompts of
a server. `prompts/list` gives the names, the titles and the arguments
of each prompt. `prompts/get` gives the messages of one prompt for the
arguments of the user.

The server checks the arguments of each `prompts/get` before it calls
the module. An unknown argument, a required argument that is missing,
or a value that is not a string gives the client the error `-32602`.
The `get/2` callback does not run.

A prompt module is a module with `use OzMcp.Config.Prompt`. One module
can declare one prompt or more.

## The two ways

A prompt module uses `use OzMcp.Config.Prompt` (DSL) or
`use OzMcp.Config.Prompt, dsl?: false` (data). Each
way runs `get/2`. The rules of the two ways and of the registration are
in [Entity modules](overview.md#the-two-ways).

## Way 1: the DSL

The DSL checks the declaration at compile time. A wrong value stops the
compilation with an error.

### A short example

```elixir
defmodule MyApp.Prompts.CompanyPrompt do
  use OzMcp.Config.Prompt

  prompt "company_overview" do
    title "Company overview"
    description "Describe the company"
    argument "acronym", required: true, description: "The acronym of the company"
  end

  @impl true
  def get(_ctx, %{"name" => "company_overview", "arguments" => %{"acronym" => acronym}}) do
    {:ok,
     %{
       messages: [
         %{role: "user", content: %{type: "text", text: "Describe the company #{acronym}."}}
       ]
     }}
  end
end
```

The `prompt` block declares one prompt. `title` and `description` are
optional. A prompt without a `title` or without a `description` gives a
message at compile time. Each `argument` line declares one argument of
the prompt. `required: true` makes the argument necessary: the client
must send a value for it at `prompts/get`.

The page [Prompt examples](../long_examples/prompt_examples.md#the-dsl)
has a long example that uses each macro of the DSL.

### The macros

`use OzMcp.Config.Prompt` imports the root macro `prompt/2` only. The
other macros work only inside their block. A macro outside its block
stops the compilation.

| Macro | Block | Value | Wire field |
|---|---|---|---|
| `prompt "name"` | root | non-empty string, unique in the module | `name` |
| `title` | `prompt` | non-empty string | `title` |
| `description` | `prompt` | non-empty string | `description` |
| `required_scopes` | `prompt` | list of scope tokens | none (a `403` and a filtered `prompts/list`) |
| `argument "name"` | `prompt` (repeatable) | name: non-empty string, unique in the prompt | one entry of `arguments` |
| `argument "name", opts` | `prompt` (repeatable) | opts: `title:`, `description:` (non-empty strings), `required:` (a boolean). Each other key stops the compilation | `arguments[].title`, `.description`, `.required` |
| `icon` | `prompt` (repeatable) | block | one entry of `icons` |
| `src` | `icon` | `https:` URL, `http:` URL of a loopback host, or `data:` URI. Required | `icons[].src` |
| `mime_type` | `icon` | non-empty string | `icons[].mimeType` |
| `sizes` | `icon` | list of `"any"` and `"WxH"` strings | `icons[].sizes` |
| `theme` | `icon` | `"light"` or `"dark"` | `icons[].theme` |
| `meta key, value` | `prompt` | key: string or atom; value: a JSON term. Each key one time | `_meta.<key>` |

The framework sends `required` on the wire only when it is `true`.

The rules of the `icon` block and of the key of `meta` are in
[Entity modules](overview.md#icons-and-_meta).

A prompt has no `annotations` block. Only a tool, a resource and a
template carry annotations.

The `use` options (`dsl?:`, `warn?:`) are in
[Entity modules](overview.md#the-use-options).

## Way 2: data

A module with `dsl?: false` writes its `list/0` function. Each entry is
a `%OzMcp.Structs.Prompt{}` struct, or a map with the wire keys (`name`,
`arguments`, ...). The rules of the entries are in
[Entity modules](overview.md#way-2-the-entries-of-list-0). The rule of
the prompt only: a nested unknown key, inside `arguments` or `icons`, is
an error that names the path. A custom value goes in `_meta`.

### A short example

The two examples below declare the same prompt.

The struct form:

```elixir
defmodule MyApp.Prompts.StructCompanyPrompt do
  use OzMcp.Config.Prompt, dsl?: false

  alias OzMcp.Structs.{Prompt, PromptArgument}

  @impl true
  def list do
    [
      %Prompt{}
      |> Prompt.name("struct_company_overview")
      |> Prompt.title("Company overview")
      |> Prompt.arguments([
        %PromptArgument{} |> PromptArgument.name("acronym") |> PromptArgument.required(true)
      ])
    ]
  end

  @impl true
  def get(_ctx, %{"name" => "struct_company_overview", "arguments" => %{"acronym" => acronym}}) do
    {:ok,
     %{messages: [%{role: "user", content: %{type: "text", text: "Describe #{acronym}."}}]}}
  end
end
```

The map form:

```elixir
defmodule MyApp.Prompts.MapCompanyPrompt do
  use OzMcp.Config.Prompt, dsl?: false

  @prompts [
    %{
      name: "map_company_overview",
      title: "Company overview",
      arguments: [%{name: "acronym", required: true}]
    }
  ]

  @impl true
  def list, do: @prompts

  @impl true
  def get(_ctx, %{"name" => "map_company_overview", "arguments" => %{"acronym" => acronym}}) do
    {:ok,
     %{messages: [%{role: "user", content: %{type: "text", text: "Describe #{acronym}."}}]}}
  end
end
```

The page [Prompt examples](../long_examples/prompt_examples.md#way-2-data)
has a long example of one prompt in the two forms, with the nested
values.

Each function of the struct module builds the wire value of its field.
Read the documentation of `OzMcp.Structs.Prompt` for the full list. The
map uses the wire keys of the MCP specification: `required`,
`mimeType`. The keys of the map go to the client as they are; the rules
above give the exceptions.

The text of a row can hold placeholders, for example
`{language}`. The store replaces each placeholder with the value of the
prompt argument of the same name.

## The callback

The `get/2` callback runs each `prompts/get` of a prompt of the module:

```elixir
@impl true
def get(ctx, params)
```

  * `ctx` is the context of the request. Read `OzMcp.Context` for the
    keys of the map, for example `ctx.session_id` and `ctx.principal`.
  * `params` is the full `params` object of the request.
    `params["name"]` is the name of the prompt.
    `params["arguments"]` is a map of strings, or absent. Use
    `Map.get(params, "arguments", %{})` when no argument is required.

The server checked the arguments before the call: an unknown argument,
a missing required argument, or a value that is not a string gave the
client the error `-32602`.

The return values:

  * `{:ok, result}`: `result` is a map, or the wire map of a
    `%OzMcp.Structs.GetPromptResult{}`. The `messages` hold one message
    for each step. The `role` of a message is `"user"` or `"assistant"`
    (`:user` or `:assistant` in a struct). The `content` of a message
    is one content block: text, image, audio, `resource_link`, or an
    embedded resource.
  * `{:error, %OzMcp.Utils.Error{}}`: a protocol error.
    `OzMcp.Utils.Error.invalid_params/2` and
    `OzMcp.Utils.Error.internal_error/2` build it with the right code.

Each other return value gives the client the error `-32603`. A result
must carry `messages` and `messages` is a list of `PromptMessage`
structs or maps. A map message follows the rules of the struct: its
`role`, when present, is `"user"` or `"assistant"` and its `content`
is a content block, checked with the rules of a block (a block whose
`type` names a block of the specification is checked with the rules of
that block). The framework builds a plain map result into its result
struct first, so a map and a struct get the same check (see
[Entity modules](overview.md#the-result-of-a-callback-struct-or-map)).
Another shape gives the error `-32603`.

A prompt module can define the optional callback `complete/4`. It gives
the values for one argument of the prompt at `completion/complete`. The
arguments:

  * 2nd argument: the name of the prompt of the reference.
  * 3rd argument: `%{"name" => argument, "value" => prefix}`. `prefix`
    is the text that the user typed.
  * 4th argument: the `context.arguments` of the request (a map), or
    `nil`.

Return `{:ok, %OzMcp.Structs.CompleteResult{}}` or `{:ok, map}`: the
`values` hold at most 100 items. Without this callback, the client gets
the error `-32601` for a completion of this prompt. The guide about
completions gives the details.

The scopes of a prompt apply to its completions: a principal without
the scopes of the prompt gets `403`.

## Register the module in a server

Register a prompt module in the `prompts` block of the server. See
[The registry blocks](../servers/declare_a_server.md#the-registry-blocks).

## Common mistakes

  * An option of `argument` that is not `title`, `description` or `required`. The compilation stops.
  * Two prompts with the same name. The compilation stops for one module and the boot stops for two modules of one server.
  * A prompt without `get/2`. The compilation stops: the behaviour requires the callback.
  * A `get/2` clause that reads `params["arguments"]` for a prompt with no required argument. The client can send no arguments and the match fails. Use `Map.get(params, "arguments", %{})` and give the arguments a default in the callback.
  * An empty `icon` block. The compilation stops: the block needs a `src`.
