defmodule OzMcp.Config.Prompt do
  @moduledoc """
  Behaviour for MCP prompt modules.

  ## Two ways to declare the prompts

  | Way | `use` | What you write | What the framework generates |
  |---|---|---|---|
  | DSL | `use OzMcp.Config.Prompt` | one `prompt "name" do ... end` block for each prompt and `get/2` | `list/0` |
  | Data | `use OzMcp.Config.Prompt, dsl?: false` | `list/0` that returns `%OzMcp.Structs.Prompt{}` structs or maps with the wire keys (`name`, `arguments`, ...) and `get/2` | nothing |

  Rules for the way with `dsl?: false`:

    * A map carries `required_scopes` like a struct: the boot of the
      instance reads the key, checks it and it never reaches the
      client.
    * The boot check of duplicate names reads `list/0` of a module one
      time at boot.

  The guide [Prompts](guides/entities/prompts.md) shows an example of
  each way.

  ## Required scopes

  Declare `required_scopes [...]` in a `prompt` block: a `prompts/get`
  without all the scopes gets `403` and `prompts/list` hides the
  prompt from a principal that lacks them. A prompt declared with
  `dsl?: false` carries the scopes in the key `required_scopes` of
  a map, or in the field of the struct. The guide about the
  authorization gives the rules of the scopes and of the filter of the
  lists.

  ## Unique key

  The `name` of a prompt is unique in the module: two prompts with the
  same `name` raise at compile time. The `name` is unique in the server
  too: the runtime refuses to boot when two prompt modules of one
  server declare the same `name`. The boot check reads `list/0` of each
  module.
  """

  alias OzMcp.Context
  alias OzMcp.Structs.{CompleteResult, GetPromptResult, Prompt}
  alias OzMcp.Utils.Error

  # ------------------------------------------------------------------
  # Behaviour definition
  # ------------------------------------------------------------------

  @type name :: String.t()

  @type rpc_params :: map()

  @type completion_argument :: %{required(String.t()) => String.t()}

  @type completion_context :: map() | nil

  @type get_result ::
          {:ok, %GetPromptResult{}}
          | {:ok, map()}
          | {:error, %Error{}}

  @type complete_result ::
          {:ok, %CompleteResult{}}
          | {:ok, map()}
          | {:error, %Error{}}

  @doc """
  Returns the prompts of the module: `%OzMcp.Structs.Prompt{}`
  structs, or maps with the wire keys.

  The DSL generates it. The boot of the instance calls it one time.
  """
  @callback list() :: list(%Prompt{}) | list(map())

  @doc """
  Gives the messages of the prompt `params["name"]`.

  `params["arguments"]` is a map of strings, or absent. The server
  checked the arguments before the call: an unknown argument, a
  missing required argument, or a value that is not a string gives the
  client a `-32602` error and `get/2` does not run.

  Return `{:ok, %GetPromptResult{}}` or `{:ok, map}`: the `messages`
  hold one message for each step. The `role` of a message is `"user"`
  or `"assistant"`. The `content` of a message is one content block:
  text, image, audio, `resource_link`, or an embedded resource.

  Return `{:error, %OzMcp.Utils.Error{}}` for a protocol error.

  ## Example

      @impl true
      def get(_ctx, %{"name" => "review", "arguments" => %{"language" => language}}) do
        {:ok,
         %{
           messages: [
             %{role: "user",
               content: %{type: "text", text: "Review this \#{language} code."}}
           ]
         }}
      end
  """
  @callback get(Context.ctx(), rpc_params()) :: get_result()

  @doc """
  Gives the values for one argument of `completion/complete`. Optional.

  The arguments:

    * `ctx`: the short context of the callbacks.
    * `name`: the name of the prompt of the reference.
    * `argument`: `%{"name" => argument, "value" => prefix}`.
      `prefix` is the text that the user typed.
    * `context`: the `context.arguments` of the request (a map of
      strings), or `nil`.

  Return `{:ok, %CompleteResult{}}` or `{:ok, map}`: the `values`
  hold at most 100 items. Without this callback, the client gets
  `-32601` for a completion of this prompt.
  """
  @callback complete(
              Context.ctx(),
              name(),
              completion_argument(),
              completion_context()
            ) :: complete_result()

  @optional_callbacks complete: 4

  defmacro __using__(opts), do: OzMcp.Config.Use.using(__MODULE__, __CALLER__, opts)

  defmacro __before_compile__(env), do: OzMcp.Config.Use.before_compile(env, {:get, 2})
end
