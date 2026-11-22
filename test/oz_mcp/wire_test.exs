defmodule OzMcp.WireTest do
  use ExUnit.Case, async: true

  use ExUnitProperties

  alias OzMcp.Wire
  alias Support.Helpers.Utils

  test "null is nil at every depth" do
    assert {:ok, %{"a" => nil, "b" => [nil, %{"c" => nil}]}} =
             Wire.decode(~s({"a":null,"b":[null,{"c":null}]}))
  end

  test "a top-level null is nil" do
    assert Wire.decode("null") == {:ok, nil}
  end

  test "true, false and the strings stay as they are" do
    assert Wire.decode(~s([true,false,"null"])) == {:ok, [true, false, "null"]}
  end

  test "a bad body is a parse error, not a raise" do
    for bad <- ["", "{", ~s({"a":}), ~s({"a":1} x), <<0xFF>>] do
      assert Wire.decode(bad) == {:error, :parse}
    end
  end

  test "decode!/1 raises for a bad body" do
    assert_raise JSON.DecodeError, fn -> Wire.decode!("{") end
  end

  describe "the bound of a number" do
    test "a number of 100 characters is accepted, one of 101 is refused" do
      ok = String.duplicate("7", 100)
      over = String.duplicate("7", 101)

      assert {:ok, [n]} = Wire.decode("[" <> ok <> "]")
      assert n == String.to_integer(ok)
      assert Wire.decode("[" <> over <> "]") == {:error, :parse}
    end

    test "the sign counts in the bound" do
      assert {:ok, _} = Wire.decode("[-" <> String.duplicate("7", 99) <> "]")
      assert Wire.decode("[-" <> String.duplicate("7", 100) <> "]") == {:error, :parse}
    end

    test "a long float is refused, in the integer part, the fraction and the exponent" do
      long = String.duplicate("7", 200)

      for body <- ["[#{long}.5]", "[1.#{long}]", "[1e#{long}]", "[1.5e#{long}]"] do
        assert Wire.decode(body) == {:error, :parse}
        assert_raise JSON.DecodeError, ~r/longer than 100/, fn -> Wire.decode!(body) end
      end
    end

    test "decode!/1 refuses a long float that JSON.decode!/1 accepts" do
      #
      # A float of 200 digits is in the range of a double.
      #
      body = "[1." <> String.duplicate("7", 200) <> "]"
      assert {:ok, _} = JSON.decode(body)
      assert_raise JSON.DecodeError, fn -> Wire.decode!(body) end
    end

    test "the message of decode!/1 holds no byte of the body" do
      secret = "s3cr3t"

      for body <- [~s({"a":"#{secret}"} x), ~s({"#{secret}":), ~s(["#{secret}\\uZZZZ"])] do
        error = assert_raise JSON.DecodeError, fn -> Wire.decode!(body) end
        refute Exception.message(error) =~ secret
      end
    end

    test "a long number at any depth is refused" do
      long = String.duplicate("7", 200)
      assert Wire.decode(~s({"a":[{"b":#{long}}]})) == {:error, :parse}
    end

    test "a long digit string as a key or a string value is not a number" do
      long = String.duplicate("7", 200)
      assert {:ok, %{^long => long2}} = Wire.decode(~s({"#{long}":"#{long}"}))
      assert long2 == long
    end

    test "a 1 MiB integer is refused without a raise" do
      body = "[" <> String.duplicate("7", 1_048_000) <> "]"
      assert Wire.decode(body) == {:error, :parse}
      assert_raise JSON.DecodeError, ~r/longer than 100/, fn -> Wire.decode!(body) end
    end

    test "a bad body after a good number is still a parse error" do
      assert Wire.decode("[1] x") == {:error, :parse}
      assert_raise JSON.DecodeError, fn -> Wire.decode!("[1] x") end
    end

    property "a number in the bound decodes to the same term as JSON.decode/1" do
      check all(
              term <- number_tree(),
              max_runs: 300
            ) do
        json = term |> Utils.encode_json()
        assert Wire.decode(json) == JSON.decode(json)
      end
    end
  end

  describe "check/1" do
    test "accepts the JSON terms" do
      assert Wire.check(%{"a" => [1, 2.5, "x", true, nil, :atom], b: %{}}) == :ok
      assert Wire.check(nil) == :ok
      assert Wire.check(false) == :ok
      assert Wire.check(0) == :ok
      assert Wire.check("text") == :ok
      assert Wire.check([]) == :ok
      assert Wire.check(%{}) == :ok
    end

    test "accepts a nested term" do
      value = %{
        "content" => [
          %{"type" => "text", "text" => "ok"},
          %{"list" => [%{"deep" => :atom}]}
        ]
      }

      assert Wire.check(value) == :ok
    end

    test "gives the path to a pid" do
      pid = self()

      assert {:error, ["data", "items", 1], {:invalid_term, ^pid}} =
               Wire.check(%{"data" => %{"items" => [1, pid]}})
    end

    test "refuses a struct" do
      now = DateTime.utc_now()

      assert {:error, ["at"], {:invalid_term, ^now}} =
               Wire.check(%{"at" => now})
    end

    test "refuses a tuple" do
      assert {:error, [], {:invalid_term, {:a, 1}}} = Wire.check({:a, 1})
    end

    test "refuses the pre-encoded JSON term" do
      bytes = "{\"a\":1},{\"a\":2}"
      term = %{"result" => %{"tools" => [{:oz_mcp_json, bytes}, %{"a" => 3}]}}

      assert {:error, ["result", "tools", 0], {:invalid_term, {:oz_mcp_json, ^bytes}}} =
               Wire.check(term)
    end

    test "refuses a map keyed by a non-atom, non-string term" do
      assert {:error, [], {:bad_key, {1, 2}}} = Wire.check(%{{1, 2} => 1})
      assert {:error, ["m"], {:bad_key, 1}} = Wire.check(%{"m" => %{1 => "one"}})
    end

    test "refuses an improper list" do
      assert {:error, ["l"], :improper_list} = Wire.check(%{"l" => [1 | 2]})
      assert {:error, [], :improper_list} = Wire.check([1 | :improper])
    end

    test "refuses a reference" do
      ref = make_ref()
      assert {:error, [], {:invalid_term, ^ref}} = Wire.check(ref)
    end

    test "refuses a string that is not valid UTF-8 as a value" do
      for bad <- [<<0xFF>>, <<0xED, 0xA0, 0x80>>, <<0xC0, 0x80>>] do
        assert {:error, [], :invalid_utf8} = Wire.check(bad)
      end
    end

    test "refuses a string that is not valid UTF-8 as a key" do
      for bad <- [<<0xFF>>, <<0xED, 0xA0, 0x80>>, <<0xC0, 0x80>>] do
        assert {:error, [], :invalid_utf8} = Wire.check(%{bad => "value"})
      end
    end

    test "gives the path of a bad string at a depth of three" do
      assert {:error, ["a", 0, "b", 0], :invalid_utf8} =
               Wire.check(%{"a" => [%{"b" => [<<0xFF>>]}]})

      assert {:error, ["a", 0, "b"], :invalid_utf8} =
               Wire.check(%{"a" => [%{"b" => %{<<0xFF>> => 1}}]})
    end

    test "accepts the non-characters and the NUL character" do
      for good <- [<<0xEF, 0xBF, 0xBE>>, <<0xEF, 0xBF, 0xBF>>, <<0>>] do
        assert Wire.check(good) == :ok
        assert Wire.check(%{good => good}) == :ok
      end
    end
  end

  describe "check/1 and a key that is an atom and a string" do
    test "refuses the same key as an atom and as a string" do
      assert {:error, [], {:duplicate_key, "a"}} = Wire.check(%{"a" => 1, a: 2})
      assert {:error, [], {:duplicate_key, "a"}} = Wire.check(%{:a => 2, "a" => 1})
    end

    test "gives the path of the nested map" do
      assert {:error, ["r", 0], {:duplicate_key, "k"}} =
               Wire.check(%{"r" => [%{"k" => 1, k: 2}]})
    end

    test "refuses the atom keys true and false" do
      assert {:error, [], {:duplicate_key, "true"}} = Wire.check(%{"true" => 1, true => 2})
      assert {:error, [], {:duplicate_key, "false"}} = Wire.check(%{"false" => 1, false => 2})
    end

    test "accepts an atom key and a string key of different text" do
      assert Wire.check(%{"a" => 1, b: 2}) == :ok
    end

    test "accepts the same key in two different maps" do
      assert Wire.check([%{"a" => 1}, %{a: 2}]) == :ok
    end
  end

  describe "format_path/1" do
    test "joins the keys and the indexes" do
      assert Wire.format_path(["content", 0, "text"]) == "content[0].text"
      assert Wire.format_path(["a", "b"]) == "a.b"
      assert Wire.format_path([0, 1]) == "[0][1]"
    end

    test "names the root for an empty path" do
      assert Wire.format_path([]) == "the root of the result"
    end
  end

  describe "to_wire/1" do
    test "changes the atom keys and the atom values to strings" do
      assert Wire.to_wire(%{result: "ok"}) == %{"result" => "ok"}

      assert Wire.to_wire(%{status: :ok, list: [:a, %{b: 1}]}) ==
               %{"status" => "ok", "list" => ["a", %{"b" => 1}]}
    end

    test "keeps nil, the booleans, the numbers and the strings" do
      assert Wire.to_wire(nil) == nil
      assert Wire.to_wire(true) == true
      assert Wire.to_wire(false) == false
      assert Wire.to_wire(0) == 0
      assert Wire.to_wire(-2.5) == -2.5
      assert Wire.to_wire("text") == "text"
    end

    test "changes :null to nil" do
      assert Wire.to_wire(:null) == nil
    end

    test "gives the same result as the wire for the sample terms" do
      samples = [
        nil,
        true,
        false,
        0,
        -1.5,
        "text",
        [],
        %{},
        :ok,
        :null,
        [1, "two", :three, nil],
        %{result: "ok", status: :ok},
        %{"nested" => [:a, %{b: true, c: nil, d: :null}]}
      ]

      for term <- samples do
        assert Wire.to_wire(term) == term |> Utils.encode_json() |> Wire.decode!()
      end
    end
  end

  describe "encode/1" do
    test "refuses a map with the same key as an atom and as a string" do
      assert Wire.encode(%{"a" => 1, a: 2}) == {:error, [], {:duplicate_key, "a"}}
    end

    test "gives the JSON text of a JSON term" do
      term = %{"a" => nil, "b" => [:null, :atom, [nil, %{c: :null}]]}

      assert {:ok, data} = Wire.encode(term)
      assert Wire.decode!(data) == Wire.to_wire(term)
    end

    test "gives an error for a bad binary and does not raise" do
      for bad <- [<<0xFF>>, <<0xED, 0xA0, 0x80>>, <<0xC0, 0x80>>] do
        assert {:error, [], :invalid_utf8} = Wire.encode(bad)
        assert {:error, ["v"], :invalid_utf8} = Wire.encode(%{"v" => bad})
        assert {:error, [], :invalid_utf8} = Wire.encode(%{bad => 1})
        assert {:error, [0], :invalid_utf8} = Wire.encode([bad])
      end
    end

    property "a binary encodes if and only if it is valid UTF-8" do
      check all(binary <- binary(), max_runs: 300) do
        expected = if String.valid?(binary), do: :ok, else: :error

        assert result_kind(Wire.encode(binary)) == expected
        assert result_kind(Wire.encode(%{"v" => binary})) == expected
        assert result_kind(Wire.encode(%{binary => 1})) == expected
        assert result_kind(Wire.encode([binary])) == expected
      end
    end

    property "every generated JSON term encodes" do
      check all(term <- json_term(), max_runs: 300) do
        assert {:ok, data} = Wire.encode(term)
        assert Wire.decode!(data) == Wire.to_wire(term)
      end
    end

    property "the encoded term of a term that check/1 accepts does not change" do
      check all(term <- json_term(), Wire.check(term) == :ok, max_runs: 300) do
        assert {:ok, data} = Wire.encode(term)
        assert Wire.decode!(data) == Wire.decode!(reference_encode(term))
      end
    end

    property "encode/1 gives the error of check/1 for a term with one bad part" do
      check all(term <- bad_term(), max_runs: 300) do
        assert {:error, _path, _reason} = expected = Wire.check(term)
        assert Wire.encode(term) == expected
        refute match?({:error, [], :not_encodable}, Wire.encode(term))
      end
    end

    test "gives the path of the map that holds the duplicate key" do
      assert Wire.encode([%{"a" => 1, a: 2}]) == {:error, [0], {:duplicate_key, "a"}}

      assert Wire.encode(%{"r" => %{"k" => [%{:k => 1, "k" => 2}]}}) ==
               {:error, ["r", "k", 0], {:duplicate_key, "k"}}
    end

    test "gives the path of a struct, a bad key and an improper list" do
      now = DateTime.utc_now()

      assert Wire.encode(%{"at" => now}) == {:error, ["at"], {:invalid_term, now}}
      assert Wire.encode(%{1 => "x"}) == {:error, [], {:bad_key, 1}}
      assert Wire.encode(%{1.5 => "x"}) == {:error, [], {:bad_key, 1.5}}
      assert Wire.encode(%{nil => "x"}) == {:error, [], {:bad_key, nil}}
      assert Wire.encode(%{"a" => [%{"b" => [1 | 2]}]}) == {:error, ["a", 0, "b"], :improper_list}
    end

    test "encodes a map with an atom key and a string key of different text" do
      assert {:ok, data} = Wire.encode(%{"a" => 1, b: 2})
      assert Wire.decode!(data) == %{"a" => 1, "b" => 2}
    end

    test "refuses the pre-encoded JSON term" do
      bytes = "{\"a\":1},{\"a\":2}"
      term = %{"result" => %{"tools" => [{:oz_mcp_json, bytes}, %{"a" => 3}]}}

      assert {:error, ["result", "tools", 0], {:invalid_term, {:oz_mcp_json, ^bytes}}} =
               Wire.encode(term)
    end
  end

  # The code of `encode/1` before the one walk: check, `nil` to `:null`,
  # then `:json.encode/1`.
  #
  defp reference_encode(term) do
    :ok = Wire.check(term)
    term |> reference_nulls() |> :json.encode() |> IO.iodata_to_binary()
  end

  defp reference_nulls(nil), do: :null
  defp reference_nulls(list) when is_list(list), do: Enum.map(list, &reference_nulls/1)

  defp reference_nulls(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key, reference_nulls(value)} end)

  defp reference_nulls(other), do: other

  defp bad_term do
    bad =
      one_of([
        constant(self()),
        constant(make_ref()),
        constant(fn -> :ok end),
        constant({:a, 1}),
        constant(DateTime.utc_now()),
        constant(<<0xFF>>),
        constant([1 | 2]),
        constant(%{1 => "x"}),
        constant(%{1.5 => "x"}),
        constant(%{nil => "x"}),
        constant(%{"a" => 1, a: 2}),
        constant(%{true => 1, "true" => 2})
      ])

    gen all(
          bad <- bad,
          wrappers <- list_of(one_of([constant(:list), string(:alphanumeric)]), max_length: 3)
        ) do
      Enum.reduce(wrappers, bad, fn
        :list, acc -> [1, acc]
        key, acc -> %{"x" => nil, key => acc}
      end)
    end
  end

  defp result_kind({:ok, _data}), do: :ok
  defp result_kind({:error, _path, _reason}), do: :error

  describe "encode_message/1" do
    test "refuses a map with the same key as an atom and as a string" do
      assert Wire.encode_message(%{"params" => %{"a" => 1, a: 2}}) == {:error, :not_encodable}
    end

    test "gives the JSON text of a message" do
      assert {:ok, data} =
               Wire.encode_message(%{"jsonrpc" => "2.0", "method" => "ping", "id" => nil})

      assert :json.decode(data) == %{"jsonrpc" => "2.0", "method" => "ping", "id" => :null}
    end

    test "refuses a term that JSON cannot encode" do
      for bad <- [self(), make_ref(), {:a, 1}, fn -> :ok end] do
        assert Wire.encode_message(%{"params" => %{"x" => bad}}) == {:error, :not_encodable}
        assert Wire.encode_message(%{"params" => [bad]}) == {:error, :not_encodable}
      end
    end

    test "refuses what is not a map" do
      assert Wire.encode_message("text") == {:error, :not_encodable}
      assert Wire.encode_message(nil) == {:error, :not_encodable}
    end

    test "refuses the pre-encoded JSON term" do
      term = %{"result" => %{"tools" => [{:oz_mcp_json, "{\"a\":1},{\"a\":2}"}, %{"a" => 3}]}}

      assert Wire.encode_message(term) == {:error, :not_encodable}
    end
  end

  describe "encode_answer/1" do
    test "gives the -32603 error with the same id when the answer cannot be encoded" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          data =
            Wire.encode_answer(%{
              "jsonrpc" => "2.0",
              "id" => 7,
              "result" => %{"text" => <<0xFF>>}
            })

          assert Wire.decode!(data) == %{
                   "jsonrpc" => "2.0",
                   "id" => 7,
                   "error" => %{"code" => -32603, "message" => "internal server error"}
                 }
        end)

      assert log =~ "result.text"
      refute log =~ "255"
    end

    test "gives the -32603 error with the same id for a duplicate key and the log names the path" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          data =
            Wire.encode_answer(%{
              "jsonrpc" => "2.0",
              "id" => 8,
              "result" => %{"structuredContent" => %{"a" => 1, a: 2}}
            })

          assert %{"id" => 8, "error" => %{"code" => -32603}} = Wire.decode!(data)
        end)

      assert log =~ "result.structuredContent"
    end

    test "gives the -32603 error with a string id" do
      data =
        Wire.encode_answer(%{"jsonrpc" => "2.0", "id" => "abc", "result" => <<0xFF>>})

      assert %{"id" => "abc", "error" => %{"code" => -32603}} = Wire.decode!(data)
    end

    test "gives the -32603 error with no id when the message has no valid id" do
      for message <- [
            %{"result" => <<0xFF>>},
            %{"id" => <<0xFF>>, "result" => <<0xFF>>},
            %{"id" => 1.5, "result" => <<0xFF>>}
          ] do
        data = Wire.encode_answer(message)
        body = Wire.decode!(data)

        refute Map.has_key?(body, "id")
        assert body["error"]["code"] == -32603
      end
    end

    test "writes a pre-encoded JSON term as one element of a list" do
      data =
        Wire.encode_answer(%{
          "jsonrpc" => "2.0",
          "id" => 9,
          "result" => %{"tools" => [{:oz_mcp_json, "{\"a\":1},{\"a\":2}"}, %{"a" => 3}]}
        })

      assert Wire.decode!(data) == %{
               "jsonrpc" => "2.0",
               "id" => 9,
               "result" => %{"tools" => [%{"a" => 1}, %{"a" => 2}, %{"a" => 3}]}
             }
    end

    test "gives the -32603 error with the same id for a payload that is not a binary" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          data =
            Wire.encode_answer(%{
              "jsonrpc" => "2.0",
              "id" => 10,
              "result" => %{"tools" => [{:oz_mcp_json, :atom}]}
            })

          assert %{"id" => 10, "error" => %{"code" => -32603}} = Wire.decode!(data)
        end)

      assert log =~ "result.tools[0]"
    end
  end

  defp json_term do
    StreamData.tree(
      base_term(),
      fn nested ->
        one_of([
          list_of(nested),
          map_of(string(:utf8), nested),
          map_of(json_key(), nested),
          mixed_map(nested)
        ])
      end
    )
  end

  # The generator of an atom can give `nil`, `true` or `false` (the string
  # "nil" names the atom `nil`) and a map with such a key is not JSON.
  #
  defp json_key do
    StreamData.filter(atom(:alphanumeric), &(&1 not in [nil, true, false]))
  end

  # A map with atom keys and string keys of different text.
  #
  defp mixed_map(nested) do
    gen all(
          atoms <- map_of(json_key(), nested, max_length: 3),
          strings <- map_of(string(:alphanumeric), nested, max_length: 3)
        ) do
      Map.merge(Map.drop(strings, Enum.map(Map.keys(atoms), &Atom.to_string/1)), atoms)
    end
  end

  defp base_term do
    one_of([
      constant(nil),
      constant(:null),
      integer(-Integer.pow(10, 30)..Integer.pow(10, 30)),
      boolean(),
      integer(),
      float(),
      atom(:alphanumeric),
      string(:utf8)
    ])
  end

  defp number_tree do
    leaf =
      StreamData.one_of([
        StreamData.integer(),
        StreamData.integer(-Integer.pow(10, 90)..Integer.pow(10, 90)),
        StreamData.float(),
        StreamData.boolean(),
        StreamData.string(:printable)
      ])

    StreamData.tree(leaf, fn child ->
      StreamData.one_of([
        StreamData.list_of(child, max_length: 4),
        StreamData.map_of(StreamData.string(:alphanumeric), child, max_length: 4)
      ])
    end)
  end
end
