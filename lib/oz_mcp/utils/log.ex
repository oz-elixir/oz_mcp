#
# Log text for a failure, without the data of the failure.
#
# The arguments of a function frame, the text of an exception, a thrown
# value and the reason of an exit can hold the bearer token. This module
# describes the failure by its type. `banner/3` gives the full text for
# a log call at level `:debug`.
#
defmodule OzMcp.Utils.Log do
  @moduledoc false

  @max_frames 10

  # The type of the failure: `raised Module`, `throw (the value is not
  # logged)`, or `exit tag`.
  #
  @spec describe(Exception.kind(), term(), Exception.stacktrace()) :: String.t()
  def describe(:throw, _value, _stacktrace), do: "throw (the value is not logged)"
  def describe(:exit, reason, _stacktrace), do: "exit " <> exit_tag(reason)

  def describe(:error, reason, stacktrace) do
    "raised " <> inspect(Exception.normalize(:error, reason, stacktrace).__struct__)
  end

  # The stacktrace with the arity of each frame instead of its arguments.
  # At most 10 frames.
  #
  @spec format_stacktrace(Exception.stacktrace()) :: String.t()
  def format_stacktrace(stacktrace) do
    stacktrace
    |> Enum.take(@max_frames)
    |> Enum.map(fn
      {module, function, args, location} when is_list(args) ->
        {module, function, length(args), location}

      {module, function, args} when is_list(args) ->
        {module, function, length(args), []}

      frame ->
        frame
    end)
    |> Exception.format_stacktrace()
  end

  # The full text of the failure. Use it for level `:debug` only.
  #
  # For a throw it holds the thrown value. For an exit it holds the reason.
  # For an exception it holds the message, which can hold a term such as a
  # connection. `OzMcp.Auth.Guard` never logs the thrown value or the exit
  # reason. It logs the message of an exception at level `:debug`.
  #
  @spec banner(Exception.kind(), term(), Exception.stacktrace()) :: String.t()
  def banner(kind, reason, stacktrace), do: Exception.format_banner(kind, reason, stacktrace)

  # The tag of an exit reason, never its detail: the detail can hold the
  # token.
  #
  defp exit_tag(reason) when is_atom(reason), do: inspect(reason)

  defp exit_tag({tag, _detail}) when is_atom(tag), do: inspect(tag)

  defp exit_tag(_reason), do: "(reason not logged)"
end
