defmodule OzMcp.Config.DSL.Rules do
  @moduledoc false

  alias OzMcp.Auth

  @tool_name ~r/\A[A-Za-z0-9_.-]{1,128}\z/
  @icon_size ~r/\A(any|[1-9][0-9]*x[1-9][0-9]*)\z/

  # A label of a prefix: a letter, then letters, digits and hyphens and
  # a letter or a digit at the end.
  #
  @meta_label ~S"[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?"
  @meta_prefix ~r"\A#{@meta_label}(?:\.#{@meta_label})*/\z"

  # The name can be empty (the specification says "unless empty").
  #
  @meta_name ~r"\A(?:[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)?\z"

  # The keys that the framework writes. A server callback may copy them.
  #
  @framework_meta_keys [
    "io.modelcontextprotocol/related-task",
    "io.modelcontextprotocol/model-immediate-response"
  ]

  # The name of an entity: 1 to 128 characters of `A-Z`, `a-z`, `0-9`,
  # `_`, `-` and `.`.
  #
  @spec tool_name(term()) :: :ok | {:error, String.t()}
  def tool_name(name) do
    if is_binary(name) and Regex.match?(@tool_name, name) do
      :ok
    else
      {:error, "must be 1 to 128 characters of A-Z, a-z, 0-9, _, - and ., got: #{inspect(name)}"}
    end
  end

  # A JSON schema whose root has the type `object`.
  #
  @spec object_schema(term()) :: :ok | {:error, String.t()}
  def object_schema(%{} = schema) do
    case Map.get(schema, :type, Map.get(schema, "type")) do
      type when type in ["object", :object] ->
        :ok

      other ->
        {:error, ~s(the root must have type: "object", got: #{inspect(other)})}
    end
  end

  def object_schema(other), do: {:error, "must be a map, got: #{inspect(other)}"}

  # An ISO 8601 date and time with an offset, as `DateTime.from_iso8601/1`
  # accepts it.
  #
  @spec iso8601(term()) :: :ok | {:error, String.t()}
  def iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _dt, _offset} -> :ok
      {:error, _} -> {:error, iso8601_message(value)}
    end
  end

  def iso8601(value), do: {:error, iso8601_message(value)}

  # An absolute URI, as `URI.new/1` accepts it with a scheme.
  #
  @spec absolute_uri(term()) :: :ok | {:error, String.t()}
  def absolute_uri(value) when is_binary(value) do
    if safe_uri?(value) or uri?(value),
      do: :ok,
      else: {:error, absolute_uri_message(value)}
  end

  def absolute_uri(value), do: {:error, absolute_uri_message(value)}

  # The cheap path accepts an input only when a scan proves that URI.new/1
  # accepts it; any other input goes to URI.new/1.
  #
  defp safe_uri?(value) do
    case scheme_rest(value) do
      {:ok, rest} -> safe_bytes?(rest) and authority_safe?(rest)
      :error -> false
    end
  end

  defp uri?(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme}} -> is_binary(scheme)
      {:error, _reason} -> false
    end
  end

  defguardp scheme_char(char)
            when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?+, ?-, ?.]

  defguardp safe_char(char)
            when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or
                   char in ~c"-._~!$&'()*+,;=/?:@%"

  defp scheme_rest(<<char, rest::binary>>) when char in ?a..?z or char in ?A..?Z,
    do: scheme_chars(rest)

  defp scheme_rest(_value), do: :error

  defp scheme_chars(<<?:, rest::binary>>), do: {:ok, rest}
  defp scheme_chars(<<char, rest::binary>>) when scheme_char(char), do: scheme_chars(rest)
  defp scheme_chars(_rest), do: :error

  defp safe_bytes?(<<>>), do: true
  defp safe_bytes?(<<char, rest::binary>>) when safe_char(char), do: safe_bytes?(rest)
  defp safe_bytes?(_rest), do: false

  defp authority_safe?("//" <> rest), do: authority?(rest)
  defp authority_safe?(_rest), do: true

  defp authority?(<<char, _rest::binary>>) when char in ~c"@:", do: false
  defp authority?(<<char, _rest::binary>>) when char in ~c"/?", do: true
  defp authority?(<<_char, rest::binary>>), do: authority?(rest)
  defp authority?(<<>>), do: true

  # The source of an icon: an `https:` URL with a host, an `http:` URL of
  # a loopback host, or a `data:` URI with a comma.
  #
  @spec icon_src(term()) :: :ok | {:error, String.t()}
  def icon_src(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, uri} -> if icon_source?(uri), do: :ok, else: {:error, icon_src_message(value)}
      _ -> {:error, icon_src_message(value)}
    end
  end

  def icon_src(value), do: {:error, icon_src_message(value)}

  # The size of an icon: the string `"any"` or a `"WxH"` string with two
  # positive integers, for example `"48x48"`.
  #
  @spec icon_size(term()) :: :ok | {:error, String.t()}
  def icon_size(value) do
    if is_binary(value) and Regex.match?(@icon_size, value),
      do: :ok,
      else: {:error, ~s(must be "any" or a "WxH" string such as "48x48", got: #{inspect(value)})}
  end

  # The size of a resource in bytes: a positive integer.
  #
  @spec resource_size(term()) :: :ok | {:error, String.t()}
  def resource_size(value) when not is_integer(value),
    do: {:error, "must be an integer, got: #{inspect(value)}"}

  def resource_size(0), do: {:error, "cannot be equals to zero"}
  def resource_size(value) when value < 1, do: {:error, "must be a positive integer"}
  def resource_size(_value), do: :ok

  # A non-empty list of `"user"` and `"assistant"` with no duplicate.
  #
  @spec audience(term()) :: :ok | {:error, String.t()}
  def audience(value) when not is_list(value),
    do: {:error, "must be a list, got: #{inspect(value)}"}

  def audience([]), do: {:error, "cannot be an empty list"}

  def audience(value) do
    cond do
      not Enum.all?(value, &(&1 in ["user", "assistant"])) ->
        {:error, ~s(elements must be "user" or "assistant", got: #{inspect(value)})}

      length(value) != length(Enum.uniq(value)) ->
        {:error, "has duplicates elements, got: #{inspect(value)}"}

      true ->
        :ok
    end
  end

  # The protocol version of a server: one of `OzMcp.Protocol.supported/0`.
  #
  @spec protocol_version(term()) :: :ok | {:error, String.t()}
  def protocol_version(value) do
    supported = OzMcp.Protocol.supported()

    if value in supported,
      do: :ok,
      else: {:error, "must be one of #{inspect(supported)}, got: #{inspect(value)}"}
  end

  # Checks the keys of a `_meta` map that server code writes. A key with a
  # reserved prefix is refused, except the keys of the framework.
  #
  @spec meta_keys(term()) :: :ok | {:error, String.t()}
  def meta_keys(nil), do: :ok

  def meta_keys(meta) when is_map(meta) and not is_struct(meta) do
    Enum.find_value(meta, :ok, fn {key, _value} ->
      case meta_key(key) do
        :ok -> nil
        {:error, _} = error -> error
      end
    end)
  end

  def meta_keys(_other), do: {:error, "must be a map"}

  # One key of a `_meta` map: a string or an atom, with no reserved prefix.
  #
  @spec meta_key(term()) :: :ok | {:error, String.t()}
  def meta_key(key) when key in @framework_meta_keys, do: :ok

  def meta_key(key) when is_atom(key) and key not in [nil, true, false],
    do: meta_key(Atom.to_string(key))

  def meta_key(key) when not is_binary(key),
    do: {:error, "bad _meta key #{inspect(key)}: not a string"}

  def meta_key(key) do
    {prefix, name} =
      case String.split(key, "/", parts: 2) do
        [name] -> {nil, name}
        [prefix, name] -> {prefix <> "/", name}
      end

    cond do
      not Regex.match?(@meta_name, name) ->
        {:error, "bad _meta key #{inspect(key)}: bad name"}

      prefix && not Regex.match?(@meta_prefix, prefix) ->
        {:error, "bad _meta key #{inspect(key)}: bad prefix"}

      prefix && reserved_prefix?(prefix) ->
        {:error, "the _meta prefix of #{inspect(key)} is reserved"}

      true ->
        :ok
    end
  end

  # A prefix is reserved when its second label is "modelcontextprotocol"
  # or "mcp". A prefix with one label is not reserved.
  #
  defp reserved_prefix?(prefix) do
    case prefix |> String.trim_trailing("/") |> String.split(".") do
      [_first, second | _rest] -> second in ["modelcontextprotocol", "mcp"]
      _ -> false
    end
  end

  defp icon_source?(%URI{scheme: "https", host: host}), do: host not in [nil, ""]
  defp icon_source?(%URI{scheme: "http", host: host}), do: Auth.loopback_host?(host)

  defp icon_source?(%URI{scheme: "data", path: path}),
    do: is_binary(path) and String.contains?(path, ",")

  defp icon_source?(_uri), do: false

  defp iso8601_message(value) do
    ~s(must be an ISO 8601 date and time with an offset, for example "2025-01-12T15:00:58Z", got: #{inspect(value)})
  end

  defp absolute_uri_message(value) do
    "must be an absolute URI with a scheme, got: #{inspect(value)}"
  end

  defp icon_src_message(value) do
    "must be an https: URL, an http: URL of a loopback host, or a data: URI, got: #{inspect(value)}"
  end
end
