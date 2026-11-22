#
# Specs: https://modelcontextprotocol.io/specification/2025-11-25/schema#resourcetemplate
#
defmodule OzMcp.Config.Template do
  @moduledoc """
  Behaviour for MCP resource template modules.

  ## Two ways to declare the templates

  | Way | `use` | What you write | What the framework generates |
  |---|---|---|---|
  | DSL | `use OzMcp.Config.Template` | one `template "name" do ... end` block for each template and `read/4` | `list/0` |
  | Data | `use OzMcp.Config.Template, dsl?: false` | `list/0` that returns `%OzMcp.Structs.ResourceTemplate{}` structs or maps with the wire keys (`uriTemplate`, `name`, ...) and `read/4` | nothing |

  Rules for the way with `dsl?: false`:

    * A map carries `required_scopes` like a struct: the boot of the
      instance reads the key, checks it and it never reaches the
      client.
    * The boot check of duplicate `uri_template` values reads `list/0`
      of a module one time at boot.

  The guide [Templates](guides/entities/templates.md) shows an example
  of each way.

  ## Required scopes

  Declare `required_scopes [...]` in a `template` block: a
  `resources/read` of a URI that the template matches without all the
  scopes gets `403` and `resources/templates/list` hides the template
  from a principal that lacks them. A template declared with
  `dsl?: false` carries the scopes in the key `required_scopes` of
  a map, or in the field of the struct. The guide about the
  authorization gives the rules of the scopes and of the filter of the
  lists.

  ## The URI template

  The `uri_template` uses RFC 6570, levels 1 to 3: `{var}`, `{+var}`,
  `{#var}`, `{.var}`, `{/var}`, `{;var}`, `{?var}`, `{&var}` and the
  lists `{a,b}`. A simple `{var}` value stops at `/`, `?` and `#`: it
  takes one segment of the URI only. Use `{+var}` for a value that has
  `/`. The server percent-decodes each value before the `read/4`
  callback receives it. A level 4 modifier (`{a*}`, `{a:3}`) is
  refused. The guide [Templates](guides/entities/templates.md) has the
  table of the operators and the security rules for the decoded values.

  ## Unique key

  The `uri_template` of a template is unique in the module: two
  templates with the same `uri_template` raise at compile time. Two
  templates with the same `name` and a different `uri_template` are
  valid. The `uri_template` is unique in the server too: the runtime
  refuses to boot when two template modules of one server declare
  the same `uri_template`. The boot check reads `list/0` of each
  module.

  Two templates whose `uri_template` strings differ only in the names
  of their variables (for example `file:///{a}` and `file:///{b}`)
  match the same URIs: the first one hides the second one. The DSL
  refuses them in one module at compile time and the runtime refuses
  two modules of one server at boot. The check reads the compiled
  matcher of the entries of each module.

  The server matches the templates in the declared order: the order of
  the `templates` block and then the order of each module. The first
  template that matches the URI wins.
  """

  alias OzMcp.Context
  alias OzMcp.Structs.{CompleteResult, ReadResourceResult, ResourceTemplate}
  alias OzMcp.Utils.Error

  # ------------------------------------------------------------------
  # Behaviour definition
  # ------------------------------------------------------------------

  @type uri :: String.t()

  @type uri_template :: String.t()

  @type rpc_params :: map()

  @type uri_params :: map()

  @type completion_argument :: %{required(String.t()) => String.t()}

  @type completion_context :: map() | nil

  @type read_result ::
          {:ok, %ReadResourceResult{}}
          | {:ok, map()}
          | {:error, %Error{}}

  @type complete_result ::
          {:ok, %CompleteResult{}}
          | {:ok, map()}
          | {:error, %Error{}}

  @doc """
  Returns the templates of the module: `%OzMcp.Structs.ResourceTemplate{}`
  structs, or maps with the wire keys.

  The DSL generates it. The boot of the instance calls it one time.
  """
  @callback list() :: list(%ResourceTemplate{}) | list(map()) | []

  @doc """
  Reads the contents of the concrete uri that matched a template.

  The arguments:

    * `ctx`: the short context of the callbacks.
    * `params`: the `params` object of `resources/read`.
      `params["uri"]` is the requested uri.
    * `uri_template`: the `uriTemplate` that matched the uri.
    * `uri_params`: the values of the variables of the template. The
      keys are strings.

  The return values are the same as `read/2` of a resource module:
  `{:ok, %ReadResourceResult{}}` (or a map), or
  `{:error, %OzMcp.Utils.Error{}}`.

  ## Example

      @impl true
      def read(_ctx, %{"uri" => uri}, "file://docs/{path}", %{"path" => path}) do
        {:ok, %{contents: [%{uri: uri, mimeType: "text/markdown", text: "# Document \#{path}"}]}}
      end
  """
  @callback read(Context.ctx(), rpc_params(), uri_template(), uri_params()) :: read_result()

  @doc """
  Gives the values for one variable of the template. Optional.

  The arguments:

    * `ctx`: the short context of the callbacks.
    * `uri_template`: the uri template of the reference, as the client
      sent it.
    * `argument`: `%{"name" => variable, "value" => prefix}`. `prefix`
      is the text that the user typed.
    * `context`: the `context.arguments` of the request (a map of
      strings), or `nil`.

  Return `{:ok, %CompleteResult{}}` or `{:ok, map}`: the `values`
  hold at most 100 items. Without this callback, the client gets
  `-32601` for a completion of this template.
  """
  @callback complete(
              Context.ctx(),
              uri_template(),
              completion_argument(),
              completion_context()
            ) :: complete_result()

  @optional_callbacks complete: 4

  defmacro __using__(opts), do: OzMcp.Config.Use.using(__MODULE__, __CALLER__, opts)

  defmacro __before_compile__(env), do: OzMcp.Config.Use.before_compile(env, {:read, 4})
end
