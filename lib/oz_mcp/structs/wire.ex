defmodule OzMcp.Structs.Wire do
  @moduledoc false

  alias OzMcp.Structs.Wire.{Field, Generate}

  defmacro __using__(opts) do
    env = %{__CALLER__ | function: {:__info__, 1}}

    {opts, _binding} =
      opts
      |> Macro.expand_literals(env)
      |> Code.eval_quoted([], __CALLER__)

    opts = Keyword.validate!(opts, [:fields, :const, :build])

    fields = opts |> Keyword.fetch!(:fields) |> Enum.map(&Field.normalize/1)

    Generate.code(fields, opts)
  end
end
