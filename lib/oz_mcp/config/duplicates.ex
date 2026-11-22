#
# Boot check: one key (tool name, resource uri, template uri_template,
# prompt name) in two modules of one server. The check reads the
# entries of each module (see OzMcp.Catalog.entries/2).
# One module never has a duplicate key: the DSL refuses it at compile
# time.
#
# For the templates, the check also compares the shape of each
# uri_template (the compiled matcher of the entry). Two templates whose
# strings differ only in the variable names have the same shape and match
# the same URIs: the first one hides the second one. The exact-key check
# of all kinds runs first, so an exact duplicate keeps its own message.
#
defmodule OzMcp.Config.Duplicates do
  @moduledoc false

  alias OzMcp.Catalog

  @kinds [
    tools: "tool name",
    resources: "resource uri",
    templates: "template uri_template",
    prompts: "prompt name"
  ]

  @spec check!(module()) :: :ok
  def check!(server) do
    config =
      if Code.ensure_loaded?(server) and function_exported?(server, :config, 0),
        do: server.config(),
        else: %{}

    Enum.each(@kinds, fn {kind, label} ->
      check_kind!(server, kind, label, Map.get(config, kind))
    end)

    check_shapes!(server, Map.get(config, :templates))
  end

  defp check_shapes!(server, %{modules: modules}) do
    modules
    |> Enum.flat_map(fn module ->
      Enum.map(shapes(module), fn {key, shape} -> {shape, key, module} end)
    end)
    |> Enum.group_by(&elem(&1, 0), fn {_shape, key, module} -> {key, module} end)
    |> Enum.sort()
    |> Enum.find_value(fn {_shape, [{key_a, mod_a} | rest]} ->
      case Enum.find(rest, fn {_key, module} -> module != mod_a end) do
        nil -> nil
        {key_b, mod_b} -> {key_a, mod_a, key_b, mod_b}
      end
    end)
    |> case do
      nil ->
        :ok

      {key_a, mod_a, key_b, mod_b} ->
        raise ArgumentError,
              "server #{inspect(server)}: the template uri_template #{inspect(key_b)} " <>
                "in #{inspect(mod_b)} has the same shape as #{inspect(key_a)} " <>
                "in #{inspect(mod_a)}"
    end
  end

  defp check_shapes!(_server, _no_block), do: :ok

  defp shapes(module) do
    module
    |> entries(:templates)
    |> Enum.map(fn entry -> {entry.key, entry.matcher.shape} end)
  end

  defp check_kind!(server, kind, label, %{modules: modules}) do
    modules
    |> Enum.flat_map(fn module -> Enum.map(entries(module, kind), &{&1.key, module}) end)
    |> Enum.group_by(fn {key, _module} -> key end, fn {_key, module} -> module end)
    |> Enum.sort()
    |> Enum.find(fn {_key, owners} -> length(owners) > 1 end)
    |> case do
      nil ->
        :ok

      {key, owners} ->
        raise ArgumentError,
              "server #{inspect(server)}: the #{label} #{inspect(key)} " <>
                "is declared in #{inspect(owners)}"
    end
  end

  defp check_kind!(_server, _kind, _label, _no_block), do: :ok

  defp entries(module, kind) do
    if Code.ensure_loaded?(module), do: Catalog.entries(module, kind), else: []
  end
end
