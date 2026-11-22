# Test support modules for the DSL test.
# These are compiled at compile-time (loaded via test_helper.exs),
# so `use` macros work correctly.
#

defmodule Support.Entities.Resources.DslTest.Basic do
  use OzMcp.Config.Resource, warn?: false

  def read(_ctx, _rpc_params), do: {:ok, %{}}

  resource "marketing.md" do
    uri "file:///marketing.md"
    title "Marketing rules"
    description "All detailed marketing rules"
    mime_type "text/markdown"
    size 2364
  end
end

defmodule Support.Entities.Resources.DslTest.WithAnnotations do
  use OzMcp.Config.Resource, warn?: false

  def read(_ctx, _rpc_params), do: {:ok, %{}}

  resource "doc.md" do
    uri "fie:///doc.md"
    title "Doc"
    description "A doc"

    annotations do
      audience ["user"]
      priority 1
      last_modified "2025-01-12T15:00:58Z"
    end
  end
end

defmodule Support.Entities.Resources.DslTest.WithIcons do
  use OzMcp.Config.Resource, warn?: false

  def read(_ctx, _rpc_params), do: {:ok, %{}}

  resource "doc.md" do
    uri "file:///doc.md"
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
end

defmodule Support.Entities.Resources.DslTest.WithMeta do
  use OzMcp.Config.Resource, warn?: false

  def read(_ctx, _rpc_params), do: {:ok, %{}}

  resource "doc.md" do
    uri "file:///doc.md"
    title "Doc"
    description "A doc"

    meta "key1", "value1"
    meta "key2", "value2"
  end
end

defmodule Support.Entities.Resources.DslTest.Multiple do
  use OzMcp.Config.Resource, warn?: false

  def read(_ctx, _rpc_params), do: {:ok, %{}}

  resource "first.md" do
    uri "file:///first.md"
    title "First"
    description "First resource"
  end

  resource "second.md" do
    uri "file:///second.md"
    title "Second"
    description "Second resource"
  end
end

defmodule Support.Entities.Resources.DslTest.Full do
  use OzMcp.Config.Resource, warn?: false

  def read(_ctx, _rpc_params), do: {:ok, %{}}

  resource "full.md" do
    uri "file:///full.md"
    title "Full Resource"
    description "A resource with everything"
    mime_type "text/markdown"
    size 4096

    annotations do
      audience ["user", "assistant"]
      priority 1
      last_modified "2025-06-01T00:00:00Z"
    end

    meta "version", "1.0"

    icon do
      src "https://assets/icon.svg"
      mime_type "image/svg+xml"
      sizes ["16x16", "32x32"]
      theme "light"
    end
  end
end
