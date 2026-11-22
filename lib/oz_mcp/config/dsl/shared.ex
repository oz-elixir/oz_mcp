#
# The rows that many DSL tables share. Each function gives a map of
# rows that a DSL module merges into its own tables at compile time.
#
defmodule OzMcp.Config.DSL.Shared do
  @moduledoc false

  alias OzMcp.Auth.Scopes
  alias OzMcp.Config.DSL.{Checks, Rules}
  alias OzMcp.Structs.{Annotations, Icon, ServerCapabilities}

  # title, description and required_scopes of an entity.
  #
  @spec entity_properties(atom()) :: map()
  def entity_properties(root) do
    %{
      title: %{paths: [[root]], field: :title, type: :non_empty_string},
      description: %{paths: [[root]], field: :description, type: :non_empty_string},
      required_scopes: %{
        paths: [[root]],
        field: :required_scopes,
        type: {:raises, &Scopes.check!/1}
      }
    }
  end

  # src, mime_type, sizes and theme of the icon block of `parent`.
  #
  @spec icon_properties(list(atom())) :: map()
  def icon_properties(parent) do
    path = parent ++ [:icon]

    %{
      src: %{
        paths: [path],
        field: :src,
        type: [:non_empty_string, {:rule, &Rules.icon_src/1}]
      },
      mime_type: %{paths: [path], field: :mimeType, type: :non_empty_string},
      sizes: %{
        paths: [path],
        field: :sizes,
        type: [{:list, "a list of string"}, {:each_rule, &Rules.icon_size/1}]
      },
      theme: %{
        paths: [path],
        field: :theme,
        type: [
          :string,
          {:one_of, ["light", "dark"], "can take only two values: 'light' or 'dark'"}
        ]
      }
    }
  end

  @spec icon_block(list(atom())) :: map()
  def icon_block(parent) do
    %{
      icon: %{
        paths: [parent],
        field: :icons,
        initial: Icon,
        mode: :repeat,
        finish: {Checks, :icon!, []}
      }
    }
  end

  @spec meta_pair(list(list(atom()))) :: map()
  def meta_pair(paths) do
    %{meta: %{paths: paths, field: :_meta, key: &Checks.meta_pair_key!/2}}
  end

  # The rows of a resource and of a resource template.
  #
  @spec resource_properties(atom()) :: map()
  def resource_properties(root) do
    annotations = [root, :annotations]

    [root]
    |> icon_properties()
    |> Map.merge(entity_properties(root))
    |> Map.merge(%{
      mime_type: %{paths: [[root], [root, :icon]], field: :mimeType, type: :non_empty_string},
      audience: %{paths: [annotations], field: :audience, type: {:rule, &Rules.audience/1}},
      priority: %{
        paths: [annotations],
        field: :priority,
        type: [:number, {:raises, &Annotations.validate_priority/1}]
      },
      last_modified: %{
        paths: [annotations],
        field: :lastModified,
        type: [:string, {:rule, &Rules.iso8601/1}]
      }
    })
  end

  @spec resource_blocks(atom()) :: map()
  def resource_blocks(root) do
    [root]
    |> icon_block()
    |> Map.put(:annotations, %{
      paths: [[root]],
      field: :annotations,
      initial: Annotations,
      finish: {Checks, :not_empty!, [[:audience, :priority, :lastModified], "annotations"]}
    })
  end

  # `tools`, `resources` and `prompts` of the server: a registry at the
  # root. `resources` also has a capability block (`subscribe`).
  #
  @spec list_block(atom(), String.t()) :: map()
  def list_block(name, entity) do
    at = %{
      [] => %{
        initial: %{paginate: nil, list_result: nil, modules: []},
        finish: {Checks, :modules!, [entity]}
      }
    }

    if name == :resources do
      %{
        paths: [[], [:capabilities]],
        field: name,
        at:
          Map.put(at, [:capabilities], %{
            initial: %{subscribe: nil},
            merge: {__MODULE__, :__merge_capability__, [name]}
          })
      }
    else
      %{paths: [[]], field: name, at: at}
    end
  end

  # The merge of the `resources` capability block into the capabilities of
  # the server.
  #
  @spec __merge_capability__(ServerCapabilities.t(), map(), atom()) :: ServerCapabilities.t()
  def __merge_capability__(parent, child, :resources) do
    ServerCapabilities.resources(parent, child.subscribe)
  end
end
