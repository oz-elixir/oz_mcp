#
# Specs: https://modelcontextprotocol.io/specification/2025-11-25/schema#resource
#
defmodule OzMcp.Config.Resource do
  @moduledoc """
  Behaviour for MCP resource modules.

  ## Two ways to declare the resources

  | Way | `use` | What you write | What the framework generates |
  |---|---|---|---|
  | DSL | `use OzMcp.Config.Resource` | one `resource "name" do ... end` block for each resource and `read/2` | `list/0` |
  | Data | `use OzMcp.Config.Resource, dsl?: false` | `list/0` that returns `%OzMcp.Structs.Resource{}` structs or maps with the wire keys (`uri`, `name`, `mimeType`, ...) and `read/2` | nothing |

  Rules for the way with `dsl?: false`:

    * A map carries `required_scopes` like a struct: the boot of the
      instance reads the key, checks it and it never reaches the
      client.
    * The boot check of duplicate uris reads `list/0` of a module one
      time at boot.

  The guide [Resources](guides/entities/resources.md) shows an example
  of each way.

  ## Required scopes

  Declare `required_scopes [...]` in a `resource` block: a
  `resources/read` or `resources/subscribe` without all the scopes gets
  `403` and `resources/list` hides the resource from a principal that
  lacks them. A resource declared with `dsl?: false` carries the scopes
  in the key `required_scopes` of a map, or in the field of the struct.
  The guide about the authorization gives the rules of the scopes and
  of the filter of the lists.

  ## Unique key

  The `uri` of a resource is unique in the module: two resources with
  the same `uri` raise at compile time. Two resources with the same
  `name` and a different `uri` are valid. The `uri` is unique in the
  server too: the runtime refuses to boot when two resource modules of
  one server declare the same `uri`. The boot check reads `list/0` of
  each module.
  """

  alias OzMcp.Context
  alias OzMcp.Structs.{CompleteResult, ReadResourceResult, Resource}
  alias OzMcp.Utils.Error

  # ------------------------------------------------------------------
  # Behaviour definition
  # ------------------------------------------------------------------

  @type uri :: String.t()

  @type rpc_params :: map()

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
  Returns the resources of the module: `%OzMcp.Structs.Resource{}`
  structs, or maps with the wire keys.

  The DSL generates it. The boot of the instance calls it one time.
  """
  @callback list() :: list(%Resource{}) | list(map()) | []

  @doc """
  Reads the contents of `params["uri"]`.

  Return `{:ok, %ReadResourceResult{}}` or `{:ok, map}`: the
  `contents` hold one `%TextResourceContents{}` (`text`) or one
  `%BlobResourceContents{}` (`blob`, Base64) for each part.

  Return `{:error, %OzMcp.Utils.Error{}}` for a protocol error. The
  framework answers an unknown uri. A resource whose data is gone:

      {:error, Error.resource_not_found(uri)}

  ## Example

      @impl true
      def read(_ctx, %{"uri" => "file:///notes.md" = uri}) do
        {:ok, %{contents: [%{uri: uri, mimeType: "text/markdown", text: "# Notes"}]}}
      end
  """
  @callback read(Context.ctx(), rpc_params()) :: read_result()

  @doc """
  Gives the values for one argument of `completion/complete`. Optional.

  The arguments:

    * `ctx`: the short context of the callbacks.
    * `uri`: the uri of the reference, as the client sent it.
    * `argument`: `%{"name" => name, "value" => prefix}`. `prefix` is
      the text that the user typed.
    * `context`: the `context.arguments` of the request (a map of
      strings), or `nil`.

  Return `{:ok, %CompleteResult{}}` or `{:ok, map}`: the `values`
  hold at most 100 items. Without this callback, the client gets
  `-32601` for a completion of this uri.
  """
  @callback complete(
              Context.ctx(),
              uri(),
              completion_argument(),
              completion_context()
            ) :: complete_result()

  @optional_callbacks complete: 4

  defmacro __using__(opts), do: OzMcp.Config.Use.using(__MODULE__, __CALLER__, opts)

  defmacro __before_compile__(env), do: OzMcp.Config.Use.before_compile(env, {:read, 2})
end
