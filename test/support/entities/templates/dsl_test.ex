# Test support modules for the template DSL test.
# These are compiled at compile-time (loaded via test_helper.exs),
# so `use` macros work correctly.
#

defmodule Support.Entities.Templates.DslTest.Basic do
  use OzMcp.Config.Template, warn?: false

  template "File documents" do
    uri_template "file://docs/{path}"
    title "Documents collection"
    description "Documents collection description"
    mime_type "text/markdown"
  end

  def read(_ctx, _rpc_params, _uri_template, _uri_params), do: {:ok, %{}}
end

defmodule Support.Entities.Templates.DslTest.WithAnnotations do
  use OzMcp.Config.Template, warn?: false

  template "File documents" do
    uri_template "file://docs/{path}"
    title "Documents collection"
    description "Documents collection description"

    annotations do
      audience ["user"]
      priority 1
      last_modified "2025-01-12T15:00:58Z"
    end
  end

  def read(_ctx, _rpc_params, _uri_template, _uri_params), do: {:ok, %{}}
end

defmodule Support.Entities.Templates.DslTest.WithIcons do
  use OzMcp.Config.Template, warn?: false

  template "File documents" do
    uri_template "file://docs/{path}"
    title "Documents collection"
    description "Documents collection description"

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

  def read(_ctx, _rpc_params, _uri_template, _uri_params), do: {:ok, %{}}
end

defmodule Support.Entities.Templates.DslTest.WithMeta do
  use OzMcp.Config.Template, warn?: false

  template "File documents" do
    uri_template "file://docs/{path}"
    title "Documents collection"
    description "Documents collection description"

    meta "key1", "value1"
    meta "key2", "value2"
  end

  def read(_ctx, _rpc_params, _uri_template, _uri_params), do: {:ok, %{}}
end

defmodule Support.Entities.Templates.DslTest.Multiple do
  use OzMcp.Config.Template, warn?: false

  template "File documents" do
    uri_template "file://docs/{path}"
    title "Documents collection"
    description "Documents collection description"
  end

  template "Database users" do
    uri_template "db://user/{userId}"
    title "User informations"
    description "Detailed user informations"
  end

  def read(_ctx, _rpc_params, _uri_template, _uri_params), do: {:ok, %{}}
end

defmodule Support.Entities.Templates.DslTest.Full do
  use OzMcp.Config.Template, warn?: false

  template "File documents" do
    uri_template "file://docs/{path}"
    title "Documents collection"
    description "Documents collection description"
    mime_type "text/markdown"

    annotations do
      audience ["assistant", "user"]
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

  def read(_ctx, _rpc_params, _uri_template, _uri_params), do: {:ok, %{}}
end
