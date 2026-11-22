# Test support modules for the Prompt DSL test.
# These are compiled at compile-time (loaded via test_helper.exs),
# so `use` macros work correctly.
#
# NOTE: `OzMcp.Config.Prompt` requires a `get/2` callback that the DSL never
# auto-generates, so every module below defines `def get(_ctx, _params), do: {:error, :no_prompt}`
# to satisfy the behaviour.
#

defmodule Support.Entities.Prompts.DslTest.Basic do
  use OzMcp.Config.Prompt, warn?: false

  prompt "code_review" do
    title "Code review"
    description "Reviews code"

    argument "language", required: true, description: "Programming language"
  end

  def get(_ctx, _params), do: {:error, :no_prompt}
end

defmodule Support.Entities.Prompts.DslTest.NoArguments do
  use OzMcp.Config.Prompt, warn?: false

  prompt "greeting" do
    title "Greeting"
    description "A prompt without arguments"
  end

  def get(_ctx, _params), do: {:error, :no_prompt}
end

defmodule Support.Entities.Prompts.DslTest.WithIcons do
  use OzMcp.Config.Prompt, warn?: false

  prompt "doc" do
    title "Doc"
    description "A doc"

    icon do
      src "https://assets/picto.png"
      mime_type "image/png"
    end

    icon do
      src "https://assets/hero.png"
      mime_type "image/jpeg"
      sizes ["1200x800"]
      theme "dark"
    end
  end

  def get(_ctx, _params), do: {:error, :no_prompt}
end

defmodule Support.Entities.Prompts.DslTest.WithMeta do
  use OzMcp.Config.Prompt, warn?: false

  prompt "doc" do
    title "Doc"
    description "A doc"

    meta "key1", "value1"
    meta "key2", "value2"
  end

  def get(_ctx, _params), do: {:error, :no_prompt}
end

defmodule Support.Entities.Prompts.DslTest.Multiple do
  use OzMcp.Config.Prompt, warn?: false

  prompt "first" do
    title "First"
    description "First prompt"
  end

  prompt "second" do
    title "Second"
    description "Second prompt"
  end

  def get(_ctx, _params), do: {:error, :no_prompt}
end

#
# A non-DSL prompt module. Its list/0 gives plain maps with string keys,
# as a module that reads its prompts from a store can do.
#
defmodule Support.Entities.Prompts.DslTest.PlainMap do
  use OzMcp.Config.Prompt, dsl?: false

  @prompts [
    %{
      "name" => "plain_prompt",
      "arguments" => [
        %{"name" => "language", "required" => true}
      ]
    }
  ]

  @impl true
  def list, do: @prompts

  @impl true
  def get(_ctx, _params), do: {:error, :no_prompt}
end

defmodule Support.Entities.Prompts.DslTest.Full do
  use OzMcp.Config.Prompt, warn?: false

  prompt "full" do
    title "Full Prompt"
    description "A prompt with everything"

    argument "language", required: true, title: "Language", description: "Programming language"
    argument "focus", description: "security | performance | style"

    meta "version", "1.0"

    icon do
      src "https://assets/icon.svg"
      mime_type "image/svg+xml"
      sizes ["16x16", "32x32"]
      theme "light"
    end
  end

  def get(_ctx, _params), do: {:error, :no_prompt}
end
