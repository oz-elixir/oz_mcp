defmodule OzMcp.Structs.PromptMessage do
  @moduledoc """
  Helper module used to build `PromptMessage` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %PromptMessage{}
    |> PromptMessage.role(:user)
    |> PromptMessage.content(
      %TextContent{}
      |> TextContent.text("Hello, world!")
    )
    |> PromptMessage.build()
  ```

  Result:

  ```elixir
  %{"content" => %{type: "text", text: "Hello, world!"}, "role" => "user"}
  ```

  Specification: [PromptMessage](https://modelcontextprotocol.io/specification/2025-11-25/schema#promptmessage)
  """

  use OzMcp.Structs.Wire,
    build: false,
    fields: [
      role: {:any, default: :user, type: quote(do: role())},
      content: {:any, type: quote(do: content())}
    ]

  alias OzMcp.Structs.{
    Builder,
    ContentBlock,
    Keys,
    Validate
  }

  @type role :: :user | :assistant

  @type content :: ContentBlock.t()

  # A role present with nil stays an error, so a missing role reads a value no role has.
  #
  @missing :__no_role__

  @doc false
  @spec check(t() | map()) :: :ok
  def check(%__MODULE__{}), do: :ok

  def check(%{} = message) do
    check_role(Keys.get(message, "role", :role, @missing))
    Validate.content(Keys.get(message, "content", :content, nil))
  end

  def check(_value), do: :ok

  defp check_role(@missing), do: :ok

  defp check_role(role) do
    if role in Validate.roles() do
      :ok
    else
      raise ArgumentError,
            "'role' elements must be \"user\" or \"assistant\", got: #{inspect(role)}"
    end
  end

  @spec build(t()) :: map()
  def build(%__MODULE__{role: role, content: content}) do
    if role not in Validate.roles() do
      raise ArgumentError,
            "'role' elements must be \"user\" or \"assistant\", got: #{inspect(role)}"
    end

    Validate.content(content)

    %{"role" => to_string(role), "content" => Builder.content(content)}
  end
end
