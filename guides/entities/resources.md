# Resources

This guide describes each way to declare a resource module and each
option of the resource DSL. A resource is data with a fixed URI that
the client can read. The introduction guide shows a first tool and a
first server.

## What a resource is

A resource is data with a URI that the client can read. The methods
`resources/list`, `resources/read`, `resources/subscribe` and
`resources/unsubscribe` use the resources of a server. `resources/list`
gives the descriptions. `resources/read` gives the contents of one URI.
A client subscribes to a URI and the server sends a notification when
the data changes.

The `uri` is the unique key of a resource. Two resources with the same
`uri` are an error. The `read/2` callback of the module gives the
contents.

A URI with variables, for example `file://docs/{path}`, is not a
resource. It is a resource template. The guide about templates
describes them.

A resource module is a module with `use OzMcp.Config.Resource`. One
module can declare one resource or more.

## The two ways

A resource module uses `use OzMcp.Config.Resource` (DSL) or
`use OzMcp.Config.Resource, dsl?: false` (data). Each
way runs `read/2`. The rules of the two ways and of the registration
are in [Entity modules](overview.md#the-two-ways).

## Way 1: the DSL

The DSL checks the declaration at compile time. A wrong value stops the
compilation with an error.

### A short example

```elixir
defmodule MyApp.Resources.CompanyResource do
  use OzMcp.Config.Resource

  resource "acme.md" do
    uri "file:///acme.md"
    title "Company informations"
    description "All detailed company informations"
    mime_type "text/markdown"
  end

  @impl true
  def read(_ctx, %{"uri" => "file:///acme.md"}) do
    {:ok,
     %{contents: [%{uri: "file:///acme.md", mimeType: "text/markdown", text: "# ACME"}]}}
  end
end
```

The `resource` block declares one resource. The block requires a `uri`.
`title` and `description` are optional. A resource without a `title` or
without a `description` gives a message at compile time. `mime_type`
tells the client the type of the contents.

The page [Resource examples](../long_examples/resource_examples.md#the-dsl)
has a long example that uses each macro of the DSL.

### The macros

`use OzMcp.Config.Resource` imports the root macro `resource/2` only.
The other macros work only inside their block. A macro outside its
block stops the compilation.

| Macro | Block | Value | Wire field |
|---|---|---|---|
| `resource "name"` | root | non-empty string | `name` |
| `uri` | `resource` | absolute URI with a scheme, unique in the module | `uri` |
| `title` | `resource` | non-empty string | `title` |
| `description` | `resource` | non-empty string | `description` |
| `mime_type` | `resource`, `icon` | non-empty string | `mimeType` |
| `size` | `resource` | integer of 1 or more (bytes) | `size` |
| `required_scopes` | `resource` | list of scope tokens | none (a `403` and a filtered `resources/list`) |
| `annotations` | `resource` | block, one time | `annotations` |
| `audience` | `annotations` | list of `"user"` and `"assistant"` | `annotations.audience` |
| `priority` | `annotations` | number from 0 to 1 | `annotations.priority` |
| `last_modified` | `annotations` | ISO 8601 date and time with an offset, for example `2025-01-12T15:00:58Z` | `annotations.lastModified` |
| `icon` | `resource` | block, repeatable | one entry of `icons` |
| `src` | `icon` | `https:` URL, `http:` URL of a loopback host, or `data:` URI. Required | `icons[].src` |
| `mime_type` | `icon` | non-empty string | `icons[].mimeType` |
| `sizes` | `icon` | list of `"any"` and `"WxH"` strings | `icons[].sizes` |
| `theme` | `icon` | `"light"` or `"dark"` | `icons[].theme` |
| `meta key, value` | `resource` | key: string or atom; value: a JSON term. Each key one time | `_meta.<key>` |

An `annotations` block with no value stops the compilation.

The rules of the `icon` block and of the key of `meta` are in
[Entity modules](overview.md#icons-and-_meta).

`required_scopes ["docs:read"]` protects the resource. A
`resources/read` or a `resources/subscribe` without all the scopes gets
the status `403`. `resources/list` hides the resource from a principal
that lacks the scopes. The guide about authorization gives the details.

The DSL generates the function `list/0`. The module cannot define it.

The `use` options (`dsl?:`, `warn?:`) are in
[Entity modules](overview.md#the-use-options).

## Way 2: data

A module with `dsl?: false` writes its `list/0` function. Each entry is
a `%OzMcp.Structs.Resource{}` struct, or a map with the wire keys (`uri`,
`name`, `mimeType`, ...). The rules of the entries are in
[Entity modules](overview.md#way-2-the-entries-of-list-0). The rule of
the resource only: a nested unknown key, inside `annotations` or `icons`,
is an error that names the path. A custom value goes in `_meta`.

### A short example

The two examples below declare the same resource.

The struct form:

```elixir
defmodule MyApp.Resources.StructCompanyResource do
  use OzMcp.Config.Resource, dsl?: false

  alias OzMcp.Structs.{ReadResourceResult, Resource, TextResourceContents}

  @impl true
  def list do
    [
      %Resource{}
      |> Resource.uri("file:///struct-acme.md")
      |> Resource.name("struct-acme.md")
      |> Resource.mime_type("text/markdown")
    ]
  end

  @impl true
  def read(_ctx, %{"uri" => uri}) do
    {:ok,
     %ReadResourceResult{}
     |> ReadResourceResult.contents([
       %TextResourceContents{}
       |> TextResourceContents.uri(uri)
       |> TextResourceContents.mime_type("text/markdown")
       |> TextResourceContents.text("# ACME")
     ])
     |> ReadResourceResult.build()}
  end
end
```

The map form:

```elixir
defmodule MyApp.Resources.MapCompanyResource do
  use OzMcp.Config.Resource, dsl?: false

  @resources [
    %{uri: "file:///map-acme.md", name: "map-acme.md", mimeType: "text/markdown"}
  ]

  @impl true
  def list, do: @resources

  @impl true
  def read(_ctx, %{"uri" => "file:///map-acme.md" = uri}) do
    {:ok, %{contents: [%{uri: uri, mimeType: "text/markdown", text: "# ACME"}]}}
  end
end
```

The page [Resource examples](../long_examples/resource_examples.md#way-2-data)
has a long example of one resource in the two forms, with the nested
values.

Each function of the struct modules builds the wire value of its field.
Read the documentation of `OzMcp.Structs.Resource` for the full list.
The map uses the wire keys of the MCP specification: `mimeType`,
`lastModified`. The keys of the map go to the client as they are; the
rules above give the exceptions.

## The callback

The `read/2` callback runs each `resources/read`:

```elixir
@impl true
def read(ctx, params)
```

  * `ctx` is the context of the request. Read `OzMcp.Context` for the
    keys of the map, for example `ctx.session_id` and
    `ctx.principal`.
  * `params` is the full `params` object of the request. `params["uri"]`
    is the URI that the client wants to read.

The return values:

  * `{:ok, result}`: `result` is a map, or the wire map of a
    `%OzMcp.Structs.ReadResourceResult{}`. The `contents` hold one
    `%OzMcp.Structs.TextResourceContents{}` (field `text`) or one
    `%OzMcp.Structs.BlobResourceContents{}` (field `blob`, Base64) for
    each part. Give each content the `uri` of the request and its
    `mimeType`.
  * `{:error, %OzMcp.Utils.Error{}}`: a protocol error. A URI that the
    server does not declare never reaches `read/2`: the framework
    answers the error `-32002`. For a declared resource whose data no
    longer exists, return the same error:

    ```elixir
    {:error, OzMcp.Utils.Error.resource_not_found(uri)}
    ```

Each other return value gives the client the error `-32603`. A result
must carry `contents`: `contents` is a list of content items. A content
item is a `TextResourceContents` or `BlobResourceContents` struct, or a
map with a `text` member (checked as a `TextResourceContents`) or a
`blob` member (checked as a `BlobResourceContents`). In each case the
`uri` of the item is a non-empty string. A map with neither a
`text` nor a `blob` gives the error `-32603` and the error names the
item (`contents[0] needs a 'text' or a 'blob'`, for example). The
framework builds a plain map result into its result struct first, so a
map and a struct get the same check (see
[Entity modules](overview.md#the-result-of-a-callback-struct-or-map)).
Another shape gives the error `-32603`.

A resource module can define the optional callback `complete/4`. It
gives the values for one variable of a template at
`completion/complete`. The guide about completions gives the details.

## Subscribe to a resource

A client subscribes to a URI with `resources/subscribe` and ends the
subscription with `resources/unsubscribe`. The subscription works only
when the server declares the capability. Write `subscribe true` in the
`capabilities` block of the server module:

```elixir
capabilities do
  resources do
    subscribe true
  end
end
```

Each session can hold at most `max_subscriptions_per_session`
subscriptions (default `1000`; `nil` sets no limit). A
`resources/subscribe` of a new URI over the limit gets the JSON-RPC
error `-32000 "too many subscriptions"`, with `data.limit` set to
`max_subscriptions_per_session`: the client can unsubscribe a
URI and subscribe again. A repeat subscribe of a URI that the session
already holds is not a new subscription.

A client can unsubscribe a URI that the server no longer finds and a URI
that it never subscribed: both answer `{}`.

A resource that declares `required_scopes` puts its scopes on the
subscription. At each later request of the session, the framework
compares the scopes of the token of that request with the scopes of
each subscription. A request is a `POST` of the session, or the open of
a `GET` stream. A subscription whose scopes the token does not
cover ends at once: the client gets no message about it and a client
that gets the scopes back must subscribe again. A subscription to a
resource with no `required_scopes` never ends this way.

When the data of a resource changes, send the notification to the
subscribed sessions:

```elixir
OzMcp.Notify.resource_updated(MyApp.ArchiveServer, "file:///definitions.md")
```

The guide about notifications gives the details.

## Register the module in a server

Register a resource module in the `resources` block of the server. See
[The registry blocks](../servers/declare_a_server.md#the-registry-blocks).

## Common mistakes

  * Two resources with the same `uri` in one module. The compilation stops, so remove the duplicate.
  * Two resources with the same `uri` in two modules of one server. Each module compiles and the runtime refuses to boot.
  * `size 0` or a negative size. The DSL refuses it. A size is an integer of 1 or more.
  * A URI with `{var}`, for example `file://docs/{path}`, in a `resource` block. The client receives the text with the braces. Use a resource template instead.
  * An `annotations` block with no `audience`, no `priority` and no `last_modified`. The compilation stops. Remove the empty block.
  * A resource without `read/2`. The compilation stops: the behaviour requires the callback.
