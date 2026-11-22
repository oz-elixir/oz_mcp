#
# The checks of one row of a DSL table. A wrong value stops the
# compilation with an ArgumentError. The text of each message is part
# of the behaviour: the tests pin it.
#
#   :string                     a binary
#   :non_empty_string           a binary, not ""
#   :compact_string             as above, with one message for the two faults
#   :boolean, :module, :map, :number
#   :non_empty_map, :empty_map, :non_empty_list
#   {:list, text}               a list; text ends "must be <text>"
#   {:positive_integer, text}   an integer >= 1; text ends "must be <text>"
#   {:one_of, values, text}     text follows the name of the property
#   {:rule, fun}                fun gives :ok or {:error, message}
#   {:each_rule, fun}           the same for each element of a list
#   {:raises, fun}              fun raises; it gives :ok or a new value
#
defmodule OzMcp.Config.DSL.Type do
  @moduledoc false

  @type check ::
          atom()
          | {:list, String.t()}
          | {:positive_integer, String.t()}
          | {:one_of, [term()], String.t()}
          | {:rule, (term() -> :ok | {:error, String.t()})}
          | {:each_rule, (term() -> :ok | {:error, String.t()})}
          | {:raises, (term() -> term())}

  @spec check!(atom(), check() | [check()], term()) :: term()
  def check!(name, checks, value) when is_list(checks) do
    Enum.reduce(checks, value, &run(name, &1, &2))
  end

  def check!(name, check, value), do: run(name, check, value)

  defp run(_name, :string, value) when is_binary(value), do: value
  defp run(name, :string, value), do: wrong(name, "a string", value)

  defp run(name, :non_empty_string, value) do
    run(name, :string, value)
    if value == "", do: fail("'#{name}' cannot be an empty string")
    value
  end

  defp run(_name, :compact_string, value) when is_binary(value) and value != "", do: value
  defp run(name, :compact_string, value), do: wrong(name, "a non-empty string", value)

  defp run(_name, :boolean, value) when is_boolean(value), do: value
  defp run(name, :boolean, value), do: wrong(name, "a boolean", value)

  defp run(_name, :module, value) when is_atom(value), do: value
  defp run(name, :module, value), do: wrong(name, "a module (atom)", value)

  defp run(_name, :map, value) when is_map(value), do: value
  defp run(name, :map, value), do: wrong(name, "a map", value)

  defp run(_name, :number, value) when is_number(value), do: value
  defp run(name, :number, value), do: wrong(name, "a number", value)

  defp run(name, :non_empty_map, value) when value == %{} do
    fail("'#{name}' cannot be an empty map")
  end

  defp run(_name, :non_empty_map, value), do: value

  defp run(_name, :empty_map, value) when value == %{}, do: value
  defp run(name, :empty_map, value), do: wrong(name, "an empty map %{}", value)

  defp run(name, :non_empty_list, []), do: fail("'#{name}' cannot be an empty list")
  defp run(_name, :non_empty_list, value), do: value

  defp run(_name, {:list, _text}, value) when is_list(value), do: value
  defp run(name, {:list, text}, value), do: wrong(name, text, value)

  defp run(_name, {:positive_integer, _text}, value) when is_integer(value) and value >= 1,
    do: value

  defp run(name, {:positive_integer, text}, value), do: wrong(name, text, value)

  defp run(name, {:one_of, values, text}, value) do
    if value in values, do: value, else: fail("'#{name}' #{text}")
  end

  defp run(name, {:rule, fun}, value) do
    case fun.(value) do
      :ok -> value
      {:error, message} -> fail("'#{name}' #{message}")
    end
  end

  defp run(name, {:each_rule, fun}, value) do
    Enum.each(value, fn element ->
      case fun.(element) do
        :ok -> :ok
        {:error, message} -> fail("'#{name}' entry #{message}")
      end
    end)

    value
  end

  defp run(_name, {:raises, fun}, value) do
    case fun.(value) do
      :ok -> value
      other -> other
    end
  end

  defp wrong(name, text, value) do
    fail("'#{name}' must be #{text}, got: #{inspect(value)}")
  end

  defp fail(message), do: raise(ArgumentError, message)
end
