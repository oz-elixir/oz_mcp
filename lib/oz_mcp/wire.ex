#
# The one place that turns JSON bytes into a term and a JSON term into
# JSON bytes. `check/1` accepts only JSON terms and finds the first term
# that is not one; a JSON null is `nil`. `encode/1` and
# `encode_answer/1` never raise; the answer that cannot be encoded
# becomes the -32603 error with the same id.
#
defmodule OzMcp.Wire do
  @moduledoc false

  alias OzMcp.Context.Error

  require Logger

  @type path :: [String.t() | atom() | non_neg_integer()]
  @type reason ::
          {:invalid_term, term()}
          | {:bad_key, term()}
          | {:duplicate_key, String.t()}
          | :improper_list
          | :invalid_utf8
          | :not_encodable

  # The bound is wide (20 digits for a 64-bit integer); the check runs
  # before the conversion, which is what costs CPU.
  #
  @max_number_chars 100

  @spec decode(binary()) :: {:ok, term()} | {:error, :parse}
  def decode(bytes) when is_binary(bytes) do
    case decode_bounded(bytes) do
      {:ok, term} -> {:ok, term}
      {:error, _reason} -> {:error, :parse}
    end
  end

  @spec decode!(binary()) :: term()
  def decode!(bytes) when is_binary(bytes) do
    case decode_bounded(bytes) do
      {:ok, term} ->
        term

      {:error, reason} ->
        #
        # Raise from the reason of the bounded decode, not with
        # `JSON.decode!/1`: it would decode a long float that the bound
        # refused. No `data` and no byte of the body in the message.
        #
        raise JSON.DecodeError, message: decode_message(reason), data: nil, offset: nil
    end
  end

  defp decode_message(:number_too_long),
    do: "a number is longer than #{@max_number_chars} characters"

  defp decode_message({:unexpected_end, _offset}), do: "unexpected end of JSON input"
  defp decode_message({_kind, offset, _bytes}), do: "invalid JSON at byte #{offset}"

  @decoders [integer: &__MODULE__.bounded_integer/1, float: &__MODULE__.bounded_float/1]

  # `JSON.decode/3` does not check the end of the input, as `JSON.decode/1`
  # does.
  #
  defp decode_bounded(bytes) do
    case JSON.decode(bytes, :ok, @decoders) do
      {term, :ok, ""} ->
        {:ok, term}

      {_term, :ok, rest} ->
        {:error, {:invalid_byte, byte_size(bytes) - byte_size(rest), :binary.at(rest, 0)}}

      # OTP turns the throw of the float decoder into this error. An escape
      # sequence is never longer than 12 bytes, so a long one is a long
      # number.
      #
      {:error, {:unexpected_sequence, _offset, text}} when byte_size(text) > @max_number_chars ->
        {:error, :number_too_long}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :throw, :number_too_long -> {:error, :number_too_long}
  end

  @doc false
  def bounded_integer(text) when byte_size(text) > @max_number_chars, do: throw(:number_too_long)
  def bounded_integer(text), do: :erlang.binary_to_integer(text)

  @doc false
  def bounded_float(text) when byte_size(text) > @max_number_chars, do: throw(:number_too_long)
  def bounded_float(text), do: :erlang.binary_to_float(text)

  # Returns `:ok`, or `{:error, path, reason}` for the first term that is not
  # a JSON term. The reasons are tagged, so a caller term is never a reason.
  #
  @spec check(term()) :: :ok | {:error, path(), reason()}
  def check(value), do: check(value, [])

  # A text for a path, for a log line: `content[0].text`. Keys and indexes
  # only, never a value.
  #
  @spec format_path(path()) :: String.t()
  def format_path([]), do: "the root of the result"

  def format_path(path) do
    path
    |> Enum.with_index()
    |> Enum.map_join(fn
      {index, _position} when is_integer(index) -> "[#{index}]"
      {key, 0} -> to_string(key)
      {key, _position} -> "." <> to_string(key)
    end)
  end

  # A text for a reason of `check/1`, for a log line or an error message.
  #
  @spec describe(reason()) :: String.t()
  def describe({:invalid_term, %module{} = struct}) do
    "struct #{inspect(module)} (#{inspect(struct, limit: 5)}). " <>
      "Convert it to a string or a map."
  end

  def describe({:invalid_term, term}), do: "#{inspect(term, limit: 5)} is not a JSON term"
  def describe({:bad_key, key}), do: "map key #{inspect(key)} is not an atom or a string"
  def describe({:duplicate_key, key}), do: "map key #{inspect(key)} is both an atom and a string"
  def describe(:improper_list), do: "improper list"
  def describe(:invalid_utf8), do: "a string that is not valid UTF-8"
  def describe(:not_encodable), do: "a value that the encoder refuses"

  # The term as the encoder writes it on the wire, decoded. Give only a term
  # that `check/1` accepts.
  #
  @spec to_wire(term()) :: term()
  def to_wire(nil), do: nil
  def to_wire(:null), do: nil
  def to_wire(value) when is_boolean(value), do: value
  def to_wire(value) when is_atom(value), do: Atom.to_string(value)
  def to_wire(value) when is_list(value), do: Enum.map(value, &to_wire/1)

  def to_wire(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, item} -> {wire_key(key), to_wire(item)} end)
  end

  def to_wire(value), do: value

  @spec encode(term()) :: {:ok, binary()} | {:error, path(), reason()}
  def encode(term), do: encode_with(term, &encoder/2)

  defp encode_with(term, encoder) do
    {:ok, term |> :json.encode(encoder) |> IO.iodata_to_binary()}
  catch
    _kind, _reason ->
      case check(term, []) do
        :ok -> {:error, [], :not_encodable}
        {:error, _path, _reason} = error -> error
      end
  end

  defp encoder(value, _encode) when is_binary(value), do: :json.encode_binary(value)
  defp encoder(value, _encode) when is_integer(value), do: :json.encode_integer(value)
  defp encoder(value, _encode) when is_float(value), do: :json.encode_float(value)
  defp encoder(nil, _encode), do: "null"
  defp encoder(value, _encode) when is_struct(value), do: throw(:not_json)
  defp encoder(value, encode) when is_map(value), do: encode_map(value, encode)
  defp encoder(value, encode), do: :json.encode_value(value, encode)

  defp encode_map(map, encode) do
    case encode_entries(:maps.to_list(map), map, encode, 0) do
      [] -> "{}"
      [[_comma | first] | rest] -> [?{, first, rest, ?}]
    end
  end

  defp encode_entries([], _map, _encode, _kind), do: []

  defp encode_entries([{key, value} | rest], map, encode, kind) when is_binary(key),
    do: encode_entry(key, value, rest, map, encode, kind, 2)

  defp encode_entries([{key, value} | rest], map, encode, kind)
       when is_atom(key) and not is_nil(key),
       do: encode_entry(Atom.to_string(key), value, rest, map, encode, kind, 1)

  defp encode_entries(_entries, _map, _encode, _kind), do: throw(:bad_key)

  defp encode_entry(text, value, rest, map, encode, kind, bit) do
    kind = key_kinds(kind, bit, map)
    entry = [?,, :json.encode_binary(text), ?: | encode.(value, encode)]
    [entry | encode_entries(rest, map, encode, kind)]
  end

  defp key_kinds(0, bit, _map), do: bit
  defp key_kinds(kind, kind, _map), do: kind
  defp key_kinds(:mixed, _bit, _map), do: :mixed

  defp key_kinds(_kind, _bit, map),
    do: if(duplicate_key(map), do: throw(:duplicate_key), else: :mixed)

  # Checks a message and encodes it: `{:ok, data}`, or
  # `{:error, :not_encodable}`.
  #
  @spec encode_message(term()) :: {:ok, binary()} | {:error, :not_encodable}
  def encode_message(message) when is_map(message) do
    case encode(message) do
      {:ok, data} -> {:ok, data}
      {:error, _path, _reason} -> {:error, :not_encodable}
    end
  end

  def encode_message(_message), do: {:error, :not_encodable}

  # The log has the path only: the reason can hold a value of the answer.
  #
  @spec encode_answer(map()) :: binary()
  def encode_answer(message) do
    case encode_with(message, &answer_encoder/2) do
      {:ok, data} ->
        data

      {:error, path, _reason} ->
        Logger.error("a response is not JSON-encodable at #{format_path(path)}")
        {:ok, data} = encode(internal_error(message))
        data
    end
  end

  # Only the framework builds this term and it gives the bytes of a
  # list that is pre-encoded at boot. A server could build it too and
  # the bytes are then written as they are; that is accepted. check/1
  # refuses the term. encode/1 does not have this clause: it also
  # writes messages whose params no check has seen.
  #
  defp answer_encoder({:oz_mcp_json, bytes}, _encode) when is_binary(bytes), do: bytes
  defp answer_encoder(value, encode), do: encoder(value, encode)

  defp internal_error(message) do
    {_status, body} = Error.build(Error.new(:rpc_internal_error), answer_id(message))
    body
  end

  defp answer_id(%{"id" => id}) when is_integer(id), do: id
  defp answer_id(%{"id" => id}) when is_binary(id), do: if(String.valid?(id), do: id)
  defp answer_id(_message), do: nil

  defp wire_key(key) when is_atom(key), do: Atom.to_string(key)
  defp wire_key(key), do: key

  defp check(nil, _path), do: :ok
  defp check(value, _path) when is_boolean(value), do: :ok
  defp check(value, _path) when is_number(value), do: :ok
  defp check(value, _path) when is_atom(value), do: :ok

  defp check(value, path) when is_binary(value) do
    if String.valid?(value),
      do: :ok,
      else: {:error, Enum.reverse(path), :invalid_utf8}
  end

  defp check(value, path) when is_list(value), do: check_list(value, 0, path)

  defp check(value, path) when is_map(value) and not is_struct(value),
    do: check_map(Map.to_list(value), value, path, 0)

  defp check(value, path), do: {:error, Enum.reverse(path), {:invalid_term, value}}

  defp check_list([], _index, _path), do: :ok

  defp check_list([head | tail], index, path) when is_list(tail) do
    with :ok <- check(head, [index | path]) do
      check_list(tail, index + 1, path)
    end
  end

  defp check_list(_improper, _index, path), do: {:error, Enum.reverse(path), :improper_list}

  defp check_map([], map, path, 3) do
    case duplicate_key(map) do
      key when is_binary(key) -> {:error, Enum.reverse(path), {:duplicate_key, key}}
      _none -> :ok
    end
  end

  defp check_map([], _map, _path, _kinds), do: :ok

  defp check_map([{key, val} | rest], map, path, kinds) when is_binary(key) do
    if String.valid?(key) do
      with(
        :ok <- check(val, [key | path]),
        do: check_map(rest, map, path, Bitwise.bor(kinds, 2))
      )
    else
      {:error, Enum.reverse(path), :invalid_utf8}
    end
  end

  defp check_map([{key, val} | rest], map, path, kinds) when is_atom(key) and not is_nil(key) do
    with :ok <- check(val, [key | path]) do
      check_map(rest, map, path, Bitwise.bor(kinds, 1))
    end
  end

  defp check_map([{key, _val} | _rest], _map, path, _kinds),
    do: {:error, Enum.reverse(path), {:bad_key, key}}

  defp duplicate_key(map) do
    Enum.find_value(Map.keys(map), fn
      key when is_atom(key) ->
        text = Atom.to_string(key)
        is_map_key(map, text) and text

      _other ->
        false
    end)
  end
end
