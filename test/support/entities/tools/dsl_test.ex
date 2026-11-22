# Test support modules for the Tool DSL test.
# These are compiled at compile-time (loaded via test_helper.exs),
# so `use` macros work correctly.
#
# NOTE: `OzMcp.Config.Tool` requires a `call/2` callback that the DSL never
# auto-generates, so every module below defines `def call(_ctx, _params), do: {:error, :no_tool}`
# to satisfy the behaviour.
#

defmodule Support.Entities.Tools.DslTest.Basic do
  use OzMcp.Config.Tool, warn?: false

  tool "get_date" do
    title "Get the current date"
    description "Get the current date formatted as %d/%m/%Y"
    input_schema %{type: "object", properties: %{}}
    output_schema %{type: "object", properties: %{}}
  end

  def call(_ctx, _params), do: {:error, :no_tool}
end

defmodule Support.Entities.Tools.DslTest.WithAnnotations do
  use OzMcp.Config.Tool, warn?: false

  tool "doc" do
    title "Doc"
    description "A doc"

    annotations do
      title "Safe doc lookup"
      read_only_hint true
      destructive_hint false
      idempotent_hint true
      open_world_hint false
    end
  end

  def call(_ctx, _params), do: {:error, :no_tool}
end

defmodule Support.Entities.Tools.DslTest.WithIcons do
  use OzMcp.Config.Tool, warn?: false

  tool "doc" do
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

  def call(_ctx, _params), do: {:error, :no_tool}
end

defmodule Support.Entities.Tools.DslTest.WithMeta do
  use OzMcp.Config.Tool, warn?: false

  tool "doc" do
    title "Doc"
    description "A doc"

    meta "key1", "value1"
    meta "key2", "value2"
  end

  def call(_ctx, _params), do: {:error, :no_tool}
end

defmodule Support.Entities.Tools.DslTest.WithExecution do
  use OzMcp.Config.Tool, warn?: false

  tool "doc" do
    title "Doc"
    description "A doc"

    execution do
      task_support "optional"
    end
  end

  def call(_ctx, _params), do: {:error, :no_tool}
end

defmodule Support.Entities.Tools.DslTest.Multiple do
  use OzMcp.Config.Tool, warn?: false

  tool "first" do
    title "First"
    description "First tool"
  end

  tool "second" do
    title "Second"
    description "Second tool"
  end

  def call(_ctx, _params), do: {:error, :no_tool}
end

defmodule Support.Entities.Tools.DslTest.Full do
  use OzMcp.Config.Tool, warn?: false

  tool "full" do
    title "Full Tool"
    description "A tool with everything"
    input_schema %{type: "object", properties: %{name: %{type: "string"}}}
    output_schema %{type: "object", properties: %{result: %{type: "string"}}}

    annotations do
      title "Full tool hints"
      read_only_hint false
      destructive_hint true
      idempotent_hint false
      open_world_hint true
    end

    meta "version", "1.0"

    icon do
      src "https://assets/icon.svg"
      mime_type "image/svg+xml"
      sizes ["16x16", "32x32"]
      theme "light"
    end

    execution do
      task_support "required"
    end
  end

  def call(_ctx, _params), do: {:error, :no_tool}
end
