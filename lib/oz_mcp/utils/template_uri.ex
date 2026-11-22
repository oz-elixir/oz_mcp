#
# The match of a URI against a resource template (RFC 6570, levels 1 to
# 3). `compile!/1` checks a static template at compile time;
# `match_compiled/2` matches it with no parse at request time.
#
# A URI longer than 16,384 bytes, or a walk over the cost bound, never
# matches.
#
defmodule OzMcp.Utils.TemplateUri do
  @moduledoc false

  alias OzMcp.Utils.TemplateUri.{Matcher, Parser}

  @max_uri_bytes 16_384

  @spec compile(String.t()) :: {:ok, map()} | {:error, String.t()}
  defdelegate compile(template), to: Parser, as: :parse

  @spec compile!(String.t()) :: map()
  def compile!(template) do
    case compile(template) do
      {:ok, compiled} ->
        compiled

      {:error, message} ->
        raise ArgumentError, "invalid URI template #{inspect(template)}: #{message}"
    end
  end

  @spec match_compiled(map(), String.t()) :: {:ok, String.t(), map()} | nil
  def match_compiled(%{template: template, prefix: prefix} = compiled, uri)
      when is_binary(uri) do
    if byte_size(uri) <= @max_uri_bytes do
      with true <- String.starts_with?(uri, prefix),
           {:ok, params} <- Matcher.run(compiled, uri) do
        {:ok, template, params}
      else
        _error -> nil
      end
    else
      nil
    end
  end

  def match_compiled(_compiled, _uri), do: nil
end
