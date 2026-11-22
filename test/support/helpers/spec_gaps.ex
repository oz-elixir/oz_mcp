#
# Finds the public functions that have no `@spec`.
#
# A public function is a `def` with docs (not `@doc false`) in a module
# without `@moduledoc false`. `@impl` callbacks and macros (`defmacro`)
# do not need a `@spec`.
#
# A function with default arguments appears one time in the docs chunk,
# with its highest arity. The check uses that arity only: the compiler
# makes a spec for each arity that the defaults allow.
#
defmodule Support.Helpers.SpecGaps do
  #
  # The public functions with no `@spec` in all the `lib/` modules of
  # `app`, as `"Module.name/arity"` strings, sorted.
  #
  @spec find(atom()) :: [String.t()]
  def find(app) do
    app
    |> Application.spec(:modules)
    |> Enum.filter(&lib_module?/1)
    |> Enum.flat_map(&gaps_of/1)
    |> Enum.sort()
  end

  # The public functions with no `@spec` of one module, as
  # `"Module.name/arity"` strings, in the order of the docs chunk. A module
  # with `@moduledoc false` gives `[]`.
  #
  @spec gaps_of(module()) :: [String.t()]
  def gaps_of(mod) do
    specs = specs_of(mod)

    for {{:function, name, arity}, _, _, doc, meta} <- docs_of(mod),
        doc != :hidden,
        not Map.has_key?(meta, :impl),
        not Map.has_key?(specs, {name, arity}) do
      "#{inspect(mod)}.#{name}/#{arity}"
    end
  end

  defp docs_of(mod) do
    case Code.fetch_docs(mod) do
      {:docs_v1, _, _, _, moduledoc, _, docs} when moduledoc != :hidden -> docs
      _ -> []
    end
  end

  defp specs_of(mod) do
    case Code.Typespec.fetch_specs(mod) do
      {:ok, specs} -> Map.new(specs)
      _ -> %{}
    end
  end

  # `Application.spec/2` in `MIX_ENV=test` lists the modules of
  # `test/support` and `test/e2e/support` too. A module belongs to the
  # app source only when its beam was compiled from a file under `lib/`.
  # Modules compiled in memory have no source and stay out.
  #
  defp lib_module?(mod) do
    case mod.module_info(:compile)[:source] do
      nil -> false
      source -> String.starts_with?(Path.absname(source), lib_prefix())
    end
  end

  defp lib_prefix, do: Path.absname(Path.join(File.cwd!(), "lib/"))
end
