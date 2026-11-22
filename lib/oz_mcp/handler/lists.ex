defmodule OzMcp.Handler.Lists do
  @moduledoc false

  alias OzMcp.Context
  alias OzMcp.Handler.{Page, Reply}
  alias OzMcp.Structs.{Builder, Prompt, Resource, ResourceTemplate, Tool}

  @lists %{
    tools: %{
      struct: Tool,
      key: :tools,
      page_size: :paginate_tools,
      meta: :list_tools_result_meta,
      extras: :list_tools_result_extras
    },
    prompts: %{
      struct: Prompt,
      key: :prompts,
      page_size: :paginate_prompts,
      meta: :list_prompts_result_meta,
      extras: :list_prompts_result_extras
    },
    resources: %{
      struct: Resource,
      key: :resources,
      page_size: :paginate_resources,
      meta: :list_resources_result_meta,
      extras: :list_resources_result_extras
    },
    templates: %{
      struct: ResourceTemplate,
      key: :resourceTemplates,
      page_size: :paginate_templates,
      meta: :list_resource_templates_result_meta,
      extras: :list_resource_templates_result_extras
    }
  }

  @spec tools(Context.t(), stream) :: {OzMcp.Handler.response(), stream} when stream: term()
  def tools(context, stream), do: run(context, :tools, stream)

  @spec prompts(Context.t(), stream) :: {OzMcp.Handler.response(), stream} when stream: term()
  def prompts(context, stream), do: run(context, :prompts, stream)

  @spec resources(Context.t(), stream) :: {OzMcp.Handler.response(), stream} when stream: term()
  def resources(context, stream), do: run(context, :resources, stream)

  @spec templates(Context.t(), stream) :: {OzMcp.Handler.response(), stream} when stream: term()
  def templates(context, stream), do: run(context, :templates, stream)

  defp run(context, kind, stream) do
    spec = Map.fetch!(@lists, kind)
    server = context.server
    size = apply(server, spec.page_size, [])

    case with(:none <- Page.encoded(context, kind, size), do: Page.list(context, kind, size)) do
      {nil, _cursor} ->
        Reply.invalid_params(context, "invalid cursor", stream)

      # The bytes of the one list of the kind: the page is built
      # without items and the bytes go in after it (they are tuples,
      # which the map of the build refuses).
      #
      {:encoded, items} ->
        result = Map.put(page_result(spec, server, [], nil), spec.key, items)
        Reply.success(context, result, stream)

      {items, next_cursor} ->
        Reply.success(context, page_result(spec, server, items, next_cursor), stream)
    end
  end

  defp page_result(spec, server, items, next_cursor) do
    Builder.page(
      spec.key,
      spec.struct,
      items,
      next_cursor,
      apply(server, spec.meta, []),
      apply(server, spec.extras, [])
    )
  end
end
