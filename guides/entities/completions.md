# Completions

This guide describes the `completion/complete` method: the capability
that the server declares, the optional `complete/4` callback and the
result. The guides about prompts and about templates describe the
modules that give the completions.

## What a completion is

A completion gives values for one argument of a prompt, or for one
variable of a resource template. The user types the start of the value
in the client. The client sends `completion/complete` with the
reference, the name of the argument or of the variable and the text of
the user. The callback of the module answers with the values. The
client shows the values as suggestions.

The method has no macro in the DSL of an entity. The DSL of a prompt
declares the arguments. The DSL of a template declares the variables of
the URI template. The values come from the optional `complete/4`
callback of the prompt module or of the template module.

## The procedure

A server answers `completion/complete` only when two things are true:

1. The server declares the capability `completions`.
2. The module of the reference defines a public `complete/4`.

Without the capability, each `completion/complete` request gives the
error `-32601` to the client. Without the callback in the module of the
reference, the request gives the error `-32601` too.

### The capability

Write `completions %{}` in the `capabilities` block of the server
module:

```elixir
defmodule MyApp.CompletionsServer do
  use OzMcp.Config.Server

  server_info do
    name "completions-server"
    version "1.0.0"
  end

  capabilities do
    completions %{}
  end

  prompts do
    prompt MyApp.Prompts.DeployPrompt
  end
end
```

The value of `completions` is the empty map `%{}`. A map with a key
stops the compilation: put such data in `experimental`. The wire sends
the field `completions` in the `capabilities` of the `initialize`
answer. The client reads this field before it sends
`completion/complete`.

### The boot check

The boot compares the capability with the callbacks one time, when an
instance of the server starts:

  * The server declares the capability and no prompt module, no
    template module and no resource module of the server defines a
    public `complete/4`: the boot stops with an error. The server can
    never answer `completion/complete`.
  * A module of the server defines `complete/4` and the server
    declares no capability: the boot logs a warning. The capability is
    absent, so each `completion/complete` gives the error `-32601` to
    the client.

The check reads the list of the modules of each registry block. A
module that defines `complete/4` counts, also a module with
`dsl?: false`.

### The callback

The callback is optional. A prompt module or a template module without
`complete/4` is valid. The method gives completions only for the
references to the modules with the callback.

## The callback

The signature is the same for a prompt and for a template:

```elixir
@impl true
def complete(ctx, ref, argument, context)
```

  * `ctx` is the context of the request. Read `OzMcp.Context` for the
    keys of the map, for example `ctx.session_id` and `ctx.principal`.
  * `ref` identifies the entity of the request.
  * `argument` names the argument or the variable and carries the text
    of the user.
  * `context` holds the values that the user selected before.

The three last arguments depend on the type of the reference:

| Argument | Prompt (`ref/prompt`) | Template (`ref/resource`) |
|---|---|---|
| 2nd | the name of the prompt | the URI of the reference, as the client sent it (usually the URI template) |
| 3rd | `%{"name" => argument, "value" => text}` | `%{"name" => variable, "value" => text}` |
| 4th | the `context.arguments` of the request (a map of strings), or `nil` | the same |

The 3rd argument is always a map with the keys `"name"` and `"value"`.
`"value"` is the text that the user typed. The value can be the empty
string.

The 4th argument is the `context.arguments` object of the request. The
client sends it when the user selected the values of the arguments
before. The client can send no `context`, or a `context` without
`arguments`: the 4th argument is `nil` then. Every value of the map
must be a string.

The server validates the request before it calls the callback:

  * The `ref` must have the type `ref/prompt` with a `name`, or the
    type `ref/resource` with a `uri`. Each other reference gives the
    error `-32602` to the client.
  * The name of a `ref/prompt` must name a prompt of the server. An
    unknown name gives the error `-32602`.
  * The URI of a `ref/resource` is a resource URI of the server, a
    template string of the server (the `uriTemplate` of one of its
    templates), or a concrete URI that a template matches. An unknown
    URI gives the error `-32002` with the data `%{"uri" => uri}`.
  * `context.arguments` must be an object and every value of the
    object must be a string. Each other form gives the error `-32602`.

## The result

Return `{:ok, result}`. The `result` is a map, or the wire map of a
`%OzMcp.Structs.CompleteResult{}`:

```elixir
{:ok,
 %OzMcp.Structs.CompleteResult{}
 |> OzMcp.Structs.CompleteResult.completion(
   %OzMcp.Structs.Completion{}
   |> OzMcp.Structs.Completion.values(["elixir", "erlang"])
   |> OzMcp.Structs.Completion.total(2)
   |> OzMcp.Structs.Completion.has_more(false)
 )
 |> OzMcp.Structs.CompleteResult.build()}
```

The same result as a plain map:

```elixir
{:ok, %{completion: %{values: ["elixir", "erlang"], total: 2, hasMore: false}}}
```

The `completion` map has the fields of this table:

| Field | Type | Wire field | Meaning |
|---|---|---|---|
| `values` | list of strings, required | `values` | the suggestions for the user. At most 100 items |
| `total` | non-negative integer, optional | `total` | the total number of the values |
| `has_more` | boolean, optional | `hasMore` | `true` when the client can ask for more values |

`%OzMcp.Structs.Completion` refuses a `values` list with more than 100
items, a list with an item that is not a string, a `total` that is not
a non-negative integer and a `hasMore` that is not a boolean. The
framework checks the same rules on every completion result that reaches
the client: a `%OzMcp.Structs.Completion{}` struct, a plain map
`completion` of a map result and a plain map `completion` that a
`%OzMcp.Structs.CompleteResult{}` holds. The rules are the same in each
case.

Each other return value gives the client the error `-32603`. A map
result must carry `completion`: `completion` is a map whose `values` is
a list of at most 100 strings, whose `total`, when present, is a
non-negative integer and whose `hasMore`, when present, is a boolean.
The framework builds a plain map
result into its result struct first, so a map and a struct get the same
check. Another shape gives the error `-32603`.

## An example with the context

The services of a deployment depend on the environment that the user
selected before. The callback reads the 4th argument and gives the
services of this environment:

```elixir
defmodule MyApp.Prompts.DeployPrompt do
  use OzMcp.Config.Prompt

  prompt "deploy" do
    title "Deploy a service"
    description "Deploy one service to one environment"
    argument "environment", required: true
    argument "service", required: true
  end

  @impl true
  def get(_ctx, %{"name" => "deploy", "arguments" => args}) do
    text = "Deploy #{args["service"]} to #{args["environment"]}."
    {:ok, %{messages: [%{role: "user", content: %{type: "text", text: text}}]}}
  end

  @impl true
  def complete(_ctx, "deploy", %{"name" => "service", "value" => prefix}, context) do
    services =
      case context do
        %{"environment" => "production"} -> ["api", "web"]
        _other -> ["api", "web", "sandbox"]
      end

    values = Enum.filter(services, &String.starts_with?(&1, prefix))
    {:ok, %{completion: %{values: values, total: length(values), hasMore: false}}}
  end

  def complete(_ctx, "deploy", %{"name" => "environment", "value" => prefix}, _context) do
    values = Enum.filter(["staging", "production"], &String.starts_with?(&1, prefix))
    {:ok, %{completion: %{values: values}}}
  end
end
```

Each clause of `complete/4` matches on the name in the 3rd argument.
The clause that matches gives the values of that argument. The client
sends this request for the argument `service` after the user selected
`production` for the argument `environment`:

```json
{"jsonrpc": "2.0", "id": 7, "method": "completion/complete",
 "params": {"ref": {"type": "ref/prompt", "name": "deploy"},
            "argument": {"name": "service", "value": "a"},
            "context": {"arguments": {"environment": "production"}}}}
```

The callback receives the 4th argument `%{"environment" => "production"}`.
The answer holds the values `["api"]`: only the service `api` starts
with the text `a`.

## The scopes

The scopes of the entity apply to its completions. Write
`required_scopes` in the `prompt` block or in the `template` block. A
principal without all the scopes gets the status `403` for
`completion/complete`. The lists `prompts/list` and
`resources/templates/list` hide the entity from this principal. The
guide about authorization gives the details.
