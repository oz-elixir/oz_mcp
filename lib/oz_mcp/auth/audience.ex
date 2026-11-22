#
# The compare of a token audience (`aud`, RFC 7519) with the canonical
# URL of the MCP endpoint (RFC 8707, section 2).
#
# The scheme and the host compare in lower case. The default port of the
# scheme is removed. The empty path and the path `/` are equal. The path
# keeps its case.
#
defmodule OzMcp.Auth.Audience do
  @moduledoc false

  # The canonical form of an absolute URI with a host, or `:error`.
  #
  @spec canonical(term()) :: {:ok, String.t()} | :error
  def canonical(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when is_binary(scheme) and is_binary(host) and host != "" ->
        path = if uri.path in [nil, "/"], do: nil, else: uri.path

        {:ok,
         URI.to_string(%URI{
           uri
           | scheme: String.downcase(scheme),
             host: String.downcase(host),
             path: path
         })}

      _ ->
        :error
    end
  end

  def canonical(_url), do: :error

  # True when one audience of the list identifies the resource URL. `nil`,
  # an empty list and a value that is not a list give false (fail closed).
  #
  @spec member?(term(), String.t()) :: boolean()
  def member?(audiences, resource_url) when is_list(audiences) do
    case canonical(resource_url) do
      {:ok, resource} -> Enum.any?(audiences, &(canonical(&1) == {:ok, resource}))
      :error -> false
    end
  end

  def member?(_audiences, _resource_url), do: false
end
