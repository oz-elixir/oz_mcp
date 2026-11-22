# Templates

This guide describes each way to declare a resource template module
and each option of the template DSL. A resource template is a URI
pattern with variables. The introduction guide shows a first tool and a
first server.

## What a resource template is

A resource template is a URI with variables, for example
`file://docs/{path}`. The client lists the templates of a server with
`resources/templates/list`. The client reads a concrete URI with
`resources/read`. The server finds the template that matches the URI
and calls the `read/4` callback of the module with the values of the
variables.

The `uri_template` is the unique key of a template. Two templates with
the same `uri_template` in one module stop the compilation. Two
templates with the same `uri_template` in two modules of one server
stop the boot. Two templates whose `uri_template` strings differ only
in the names of their variables (for example `file:///{a}` and
`file:///{b}`) match the same URIs and stop the compilation in one
module or the boot in two modules too.

The server matches the templates in the declared order: the order of the
`templates` block and then the order of each module. The first template
that matches the URI wins. A template of a module that the server lists
first has priority over a template of a later module, even when the
literal prefix of the later template is longer.

The variables use the levels 1 to 3 of RFC 6570. This table shows each
operator, the URIs that it matches and the values that `read/4`
receives:

| Form | Matches | Example template | Example URI | Params |
|---|---|---|---|---|
| `{var}` | one segment: stops at `/`, `?`, `#` | `app://users/{id}` | `app://users/42` | `%{"id" => "42"}` |
| `{a,b}` | one value for each variable, separated by `,` | `r/{a,b}` | `r/1,2` | `%{"a" => "1", "b" => "2"}` |
| `{+var}` | any text up to `#`, `/` included | `file:///{+path}` | `file:///a/b.md` | `%{"path" => "a/b.md"}` |
| `{#var}` | a fragment after `#` | `doc{#frag}` | `doc#intro` | `%{"frag" => "intro"}` |
| `{.var}` | a label after `.` | `img{.ext}` | `img.png` | `%{"ext" => "png"}` |
| `{/var}` | path segments after `/` | `api{/ver,id}` | `api/v1/7` | `%{"ver" => "v1", "id" => "7"}` |
| `{;var}` | optional `;name=value` parameters, any order | `m{;lang,page}` | `m;page=2;lang=en` | `%{"page" => "2", "lang" => "en"}` |
| `{?var}` | optional query values, any order | `app://s{?q,page}` | `app://s?page=2` | `%{"page" => "2"}` |
| `{&var}` | query values added to a query that exists | `s?x=1{&q}` | `s?x=1&q=a` | `%{"q" => "a"}` |

The rules of the match:

  * A simple `{var}` value stops at `/`, `?` and `#`. It never takes the
    rest of the URI. Use `{+var}` for a value that has `/`.
  * A `{.var}` value stops at `.` too, a `{/var}` value stops at `/`
    too and the value of a `{;...}` pair stops at `;` too. A decoded
    `/` in the value of `{var}`, `{.var}`, `{/var}` or `{;...}` gives
    no match.
  * The server percent-decodes each value: `%20` becomes a space and a
    `+` stays a `+`. A value with a bad triplet (`%zz`) or a sequence
    that is not valid UTF-8 after the decode gives no match.
  * For `{?...}`, `{&...}` and `{;...}`, each variable is optional, the
    names come in any order and an unknown name is ignored. A known
    name two times in the URI gives no match.
  * Two expressions can follow each other with no literal between them
    only when the second one has a prefix operator. The value of the
    first one stops before the prefix character of the second one:
    `file:///{+path}{.ext}` with `file:///a/b.md` gives
    `%{"path" => "a/b", "ext" => "md"}` and `file:///{+path}{?v}` with
    `file:///a/b?v=1` gives `%{"path" => "a/b", "v" => "1"}`. A `?`,
    `;` or `&` in the value must then come as a percent triplet
    (`%3F`). `{;...}` followed by `{....}` is refused.
  * A `{?...}` or `{&...}` expression reads the remainder of the URI up
    to `#`. It must be the last expression of the template: only a
    `{#...}` expression can follow it. A template holds at most 16
    expressions.
  * A level 4 modifier (`{a*}`, `{a:3}`) stops the compilation. A
    template that is not valid stops the compilation too, with the
    position of the fault.

### Security

The server decodes the values before the `read/4` callback runs. A value
of `{+path}` can contain `/` and `..`. A simple `{var}` value has no
`/`, but it can be `..`. Check the value before the callback reads a
file or builds a path from it. A `uri` longer than 16,384 bytes never
matches a template: the server gives the not-found error before it runs
the match.

A URI without variables is a resource. The guide about resources
describes the resources. For a `resources/read` request, the server
examines the resources first and then the templates.

A template module is a module with `use OzMcp.Config.Template`. One
module can declare one template or more.

## The two ways

A template module uses `use OzMcp.Config.Template` (DSL) or
`use OzMcp.Config.Template, dsl?: false` (data). Each
way runs `read/4`. The rules of the two ways and of the registration
are in [Entity modules](overview.md#the-two-ways).

## Way 1: the DSL

The DSL checks the declaration at compile time. A wrong value stops the
compilation with an error.

### A short example

```elixir
defmodule MyApp.Templates.CompanyTemplate do
  use OzMcp.Config.Template

  template "Company documents" do
    uri_template "file://company/{doc}"
    title "Company documents collection"
    description "The documents of the company"
    mime_type "text/markdown"
  end

  @impl true
  def read(_ctx, %{"uri" => uri}, "file://company/{doc}", %{"doc" => doc}) do
    {:ok, %{contents: [%{uri: uri, mimeType: "text/markdown", text: "# Document #{doc}"}]}}
  end
end
```

The `template` block declares one template. The block requires a
`uri_template`. `title` and `description` are optional. A template
without a `title` or without a `description` gives a message at compile
time. `mime_type` tells the client the type of the contents.

A read of `file://company/acme` gives the value `acme` for the variable
`doc` and the callback returns the contents of the document `acme`.

The page [Template examples](../long_examples/template_examples.md#the-dsl)
has a long example that uses each macro of the DSL.

### The macros

`use OzMcp.Config.Template` imports the root macro `template/2` only.
The other macros work only inside their block. A macro outside its
block stops the compilation.

| Macro | Block | Value | Wire field |
|---|---|---|---|
| `template "name"` | root | non-empty string | `name` |
| `uri_template` | `template` | non-empty string, unique in the module | `uriTemplate` |
| `title` | `template` | non-empty string | `title` |
| `description` | `template` | non-empty string | `description` |
| `mime_type` | `template`, `icon` | non-empty string | `mimeType` |
| `required_scopes` | `template` | list of scope tokens | none (a `403` and a filtered `resources/templates/list`) |
| `annotations` | `template` | block, one time | `annotations` |
| `audience` | `annotations` | list of `"user"` and `"assistant"` | `annotations.audience` |
| `priority` | `annotations` | number from 0 to 1 | `annotations.priority` |
| `last_modified` | `annotations` | ISO 8601 date and time with an offset, for example `2025-01-12T15:00:58Z` | `annotations.lastModified` |
| `icon` | `template` | block, repeatable | one entry of `icons` |
| `src` | `icon` | `https:` URL, `http:` URL of a loopback host, or `data:` URI. Required | `icons[].src` |
| `mime_type` | `icon` | non-empty string | `icons[].mimeType` |
| `sizes` | `icon` | list of `"any"` and `"WxH"` strings | `icons[].sizes` |
| `theme` | `icon` | `"light"` or `"dark"` | `icons[].theme` |
| `meta key, value` | `template` | key: string or atom; value: a JSON term. Each key one time | `_meta.<key>` |

An `annotations` block with no value stops the compilation.

The rules of the `icon` block and of the key of `meta` are in
[Entity modules](overview.md#icons-and-_meta).

A template has no `size`. A size describes one fixed resource, not a
URI pattern.

`required_scopes ["docs:read"]` protects the template. A
`resources/read` of a URI that the template matches without all the
scopes gets the status `403`. `resources/templates/list` hides the
template from a principal that lacks the scopes. The guide about
authorization gives the details.

The server matches the requested URI with each `uri_template`, in the
order of the module. It returns the first template that matches. The DSL
generates the function `list/0`. The module cannot define it.

The `use` options (`dsl?:`, `warn?:`) are in
[Entity modules](overview.md#the-use-options).

## Way 2: data

A module with `dsl?: false` writes its `list/0` function. Each entry is
a `%OzMcp.Structs.ResourceTemplate{}` struct, or a map with the wire
keys (`uriTemplate`, `name`, ...). The rules of the entries are in
[Entity modules](overview.md#way-2-the-entries-of-list-0). The rule of
the template only: a nested unknown key, inside `annotations` or
`icons`, is an error that names the path. A custom value goes in `_meta`.

### A short example

The two examples below declare the same template.

The struct form:

```elixir
defmodule MyApp.Templates.StructCompanyTemplate do
  use OzMcp.Config.Template, dsl?: false

  alias OzMcp.Structs.ResourceTemplate

  @impl true
  def list do
    [
      %ResourceTemplate{}
      |> ResourceTemplate.uri_template("file://struct-company/{doc}")
      |> ResourceTemplate.name("Company documents")
      |> ResourceTemplate.mime_type("text/markdown")
    ]
  end

  @impl true
  def read(_ctx, %{"uri" => uri}, "file://struct-company/{doc}", %{"doc" => doc}) do
    {:ok, %{contents: [%{uri: uri, mimeType: "text/markdown", text: "# Document #{doc}"}]}}
  end
end
```

The map form:

```elixir
defmodule MyApp.Templates.MapCompanyTemplate do
  use OzMcp.Config.Template, dsl?: false

  @templates [
    %{uriTemplate: "file://map-company/{doc}", name: "Company documents", mimeType: "text/markdown"}
  ]

  @impl true
  def list, do: @templates

  @impl true
  def read(_ctx, %{"uri" => uri}, "file://map-company/{doc}", %{"doc" => doc}) do
    {:ok, %{contents: [%{uri: uri, mimeType: "text/markdown", text: "# Document #{doc}"}]}}
  end
end
```

The page [Template examples](../long_examples/template_examples.md#way-2-data)
has a long example of one template in the two forms, with the nested
values.

Each function of the struct module builds the wire value of its field.
Read the documentation of `OzMcp.Structs.ResourceTemplate` for the full
list. The map uses the wire keys of the MCP specification:
`uriTemplate`, `lastModified`. The keys of the map go to the client as
they are; the rules above give the exceptions.

The server matches the URI with each `uriTemplate` of `list()`, in the
order of the list. A module is read one time at boot and a lookup
reads the catalog in the same order.

## The callback

The `read/4` callback runs each `resources/read` of a URI that a
template matches:

```elixir
@impl true
def read(ctx, params, uri_template, uri_params)
```

  * `ctx` is the context of the request. Read `OzMcp.Context` for the
    keys of the map, for example `ctx.session_id` and `ctx.principal`.
  * `params` is the full `params` object of the request. `params["uri"]`
    is the URI that the client wants to read.
  * `uri_template` is the `uriTemplate` that matched the URI.
  * `uri_params` is the map of the values of the variables. The keys are
    strings.

The return values are the return values of `read/2` of a resource
module:

  * `{:ok, result}`: `result` is a map, or the wire map of a
    `%OzMcp.Structs.ReadResourceResult{}`. The `contents` hold one
    `%OzMcp.Structs.TextResourceContents{}` (field `text`) or one
    `%OzMcp.Structs.BlobResourceContents{}` (field `blob`, Base64) for
    each part. Give each content the `uri` of the request and its
    `mimeType`.
  * `{:error, %OzMcp.Utils.Error{}}`: a protocol error, for example the
    error `-32002` for a document that does not exist:

    ```elixir
    {:error, OzMcp.Utils.Error.resource_not_found(uri)}
    ```

Each other return value gives the client the error `-32603`. A result
follows the rules of a result of `read/2`: it must carry `contents`, a
list of `TextResourceContents` or `BlobResourceContents` structs, or of
maps with a `text` or a `blob` member. The `uri` of each item is a
non-empty string. A map and a struct get the same check (see
[Entity modules](overview.md#the-result-of-a-callback-struct-or-map)).
Another shape gives the error `-32603`. See
[Resources](resources.md#the-callback) for the full rule.

A template module can define the optional callback `complete/4`. It
gives the values for one variable of the template at
`completion/complete`. The arguments:

  * 2nd argument: the `uri` of the reference, as the client sent it. A
    client sends usually the URI template itself. The server finds the
    template when the `uri` is the template string itself, or a
    concrete URI that the template matches.
  * 3rd argument: `%{"name" => variable, "value" => prefix}`. `prefix`
    is the text that the user typed.
  * 4th argument: the `context.arguments` of the request (a map), or
    `nil`.

Return `{:ok, %OzMcp.Structs.CompleteResult{}}` or `{:ok, map}`: the
`values` hold at most 100 items. Without this callback, the client gets
the error `-32601` for a completion of this template. The guide about
completions gives the details.

## Register the module in a server

Register a template module in the `templates` block of the server. See
[The registry blocks](../servers/declare_a_server.md#the-registry-blocks).

Two template modules of one server that declare templates of the
same shape (two `uri_template` strings that differ only in the names of
their variables, for example `file:///{a}` and `file:///{b}`) stop the
boot: the first template would hide the second one.

## Common mistakes

  * A level 4 modifier in a `uri_template`, for example `{a*}` or `{a:3}`. The compilation stops. Use `{+var}` for a value that has `/`.
  * Two templates that match the same URI, in one module or in two modules of one server. The first module of the server wins and the first template of the module wins.
  * A template module in the `resources` block of a server, or a resource module in the `templates` block. A read fails with the error `-32603` and the list methods give wrong entries.
  * An `annotations` block with no `audience`, no `priority` and no `last_modified`. The compilation stops. Remove the empty block.
  * A template without `read/4`. The compilation stops: the behaviour requires the callback.
