#
# Calls a callback of the application and never lets its failure, or its
# data, reach the log. The data of the application can hold the bearer
# token of the caller.
#
# A failure writes one log line at level `:error`: the module of the
# exception (a raise), the word `throw`, or the tag of an exit reason.
# The stacktrace of a raise holds no arguments of the frames. The text
# of an exception is logged at level `:debug` only.
#
defmodule OzMcp.Auth.Guard do
  @moduledoc false

  alias OzMcp.Auth.Principal
  alias OzMcp.Utils.Log

  require Logger

  # Calls the callback of the application.
  #
  # Returns `{:ok, value}` when the callback returns. Returns `:failed`
  # when it raises, throws, or exits: the failure is a defect of the
  # application and the caller must fail closed.
  #
  @spec call(String.t(), (-> term())) :: {:ok, term()} | :failed
  def call(label, fun) do
    {:ok, fun.()}
  rescue
    error ->
      Logger.error(
        "#{label} failed: " <>
          Log.describe(:error, error, __STACKTRACE__) <>
          "\n" <> Log.format_stacktrace(__STACKTRACE__)
      )

      Logger.debug(fn -> "#{label} failure text: " <> Exception.message(error) end)
      :failed
  catch
    kind, reason ->
      Logger.error("#{label} failed: " <> Log.describe(kind, reason, __STACKTRACE__))
      :failed
  end

  # Describes the shape of a returned value, never its content. A tuple
  # of size 2 with an atom tag also names the type of its second element:
  # the developer sees why the value is wrong.
  #
  @spec shape(term()) :: String.t()
  def shape(value) when is_struct(value, Principal),
    do: shape_subject(value.subject)

  def shape(value) when is_struct(value), do: "struct #{inspect(value.__struct__)}"

  def shape(value) when is_atom(value), do: inspect(value)

  def shape({tag, second}) when is_atom(tag),
    do: "tuple #{inspect(tag)} of size 2 (second element: #{element(second)})"

  def shape(value) when is_tuple(value) and tuple_size(value) > 0 do
    case elem(value, 0) do
      tag when is_atom(tag) -> "tuple #{inspect(tag)} of size #{tuple_size(value)}"
      _ -> "tuple of size #{tuple_size(value)}"
    end
  end

  def shape(value) when is_map(value), do: "map"
  def shape(value) when is_binary(value), do: "binary"
  def shape(value) when is_list(value), do: "list"
  def shape(_value), do: "term"

  # The type of an element, never its value.
  #
  defp shape_subject(subject) when is_binary(subject) and subject != "", do: "principal"
  defp shape_subject(_subject), do: "principal with an empty or non-binary subject"

  defp element(value) when is_struct(value, Principal), do: shape(value)
  defp element(value) when is_struct(value), do: shape(value)
  defp element(nil), do: "nil"
  defp element(value) when is_boolean(value), do: "boolean"
  defp element(value) when is_atom(value), do: "atom"
  defp element(value) when is_binary(value), do: "binary"
  defp element(value) when is_integer(value), do: "integer"
  defp element(value) when is_float(value), do: "float"
  defp element(value) when is_list(value), do: "list"
  defp element(value) when is_map(value), do: "map"
  defp element(value) when is_tuple(value), do: "tuple of size #{tuple_size(value)}"
  defp element(_value), do: "term"
end
