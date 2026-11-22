defmodule OzMcp.Structs.KeysTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.Keys

  @fields [:name, :inputSchema]
  @keys_spec Keys.spec(@fields)

  describe "spec/1" do
    test "holds the fields and the names" do
      assert Keys.spec(@fields) == %{
               fields: [:name, :inputSchema],
               names: %{"name" => :name, "inputSchema" => :inputSchema}
             }
    end
  end

  describe "split/2" do
    test "an atom key goes to the known fields" do
      {known, unknown} = Keys.split(%{name: "get", inputSchema: %{}}, @keys_spec)

      assert known == %{name: "get", inputSchema: %{}}
      assert unknown == %{}
    end

    test "a string key goes to the known fields" do
      {known, unknown} = Keys.split(%{"name" => "get", "inputSchema" => %{}}, @keys_spec)

      assert known == %{name: "get", inputSchema: %{}}
      assert unknown == %{}
    end

    test "both forms of one field keep the string key" do
      {known, unknown} = Keys.split(%{"name" => "wire", name: "call"}, @keys_spec)

      assert known == %{name: "wire"}
      assert unknown == %{}
    end

    test "an unknown atom key goes to the unknown members" do
      {known, unknown} = Keys.split(%{name: "get", vendor: 1}, @keys_spec)

      assert known == %{name: "get"}
      assert unknown == %{vendor: 1}
    end

    test "an unknown string key goes to the unknown members" do
      {known, unknown} = Keys.split(%{"name" => "get", "vendor" => 1}, @keys_spec)

      assert known == %{name: "get"}
      assert unknown == %{"vendor" => 1}
    end

    test "both forms of one unknown key stay in the unknown members" do
      {known, unknown} = Keys.split(%{:name => "get", :vendor => 1, "vendor" => 2}, @keys_spec)

      assert known == %{name: "get"}
      assert unknown == %{:vendor => 1, "vendor" => 2}
    end

    test "a key that is not an atom or a string goes to the unknown members" do
      {known, unknown} = Keys.split(%{:name => "get", 1 => "x"}, @keys_spec)

      assert known == %{name: "get"}
      assert unknown == %{1 => "x"}
    end

    test "a nil value is kept in the known fields" do
      {known, unknown} = Keys.split(%{"name" => "get", "inputSchema" => nil}, @keys_spec)

      assert known == %{name: "get", inputSchema: nil}
      assert unknown == %{}
    end

    test "an empty map gives two empty maps" do
      assert Keys.split(%{}, @keys_spec) == {%{}, %{}}
    end
  end

  describe "known/2" do
    test "an atom key goes to the known fields" do
      assert Keys.known(%{name: "get", vendor: 1}, @keys_spec) == %{name: "get"}
    end

    test "a string key goes to the known fields" do
      assert Keys.known(%{"name" => "get"}, @keys_spec) == %{name: "get"}
    end

    test "both forms of one field keep the string key" do
      assert Keys.known(%{"name" => "wire", name: "call"}, @keys_spec) == %{name: "wire"}
    end

    test "a field that is absent stays out" do
      assert Keys.known(%{}, @keys_spec) == %{}
    end

    test "a nil value is kept" do
      assert Keys.known(%{"inputSchema" => nil}, @keys_spec) == %{inputSchema: nil}
    end
  end

  describe "get/4" do
    test "the string key wins over the atom key of the same field" do
      assert Keys.get(%{"name" => "wire", name: "call"}, "name", :name, "d") == "wire"
    end

    test "an atom key alone gives its value" do
      assert Keys.get(%{name: "call"}, "name", :name, "d") == "call"
    end

    test "a missing key gives the default" do
      assert Keys.get(%{}, "name", :name, "d") == "d"
      assert Keys.get(%{"other" => 1}, "name", :name, nil) == nil
    end

    test "a present nil value is kept" do
      assert Keys.get(%{"inputSchema" => nil}, "inputSchema", :inputSchema, "d") == nil
    end
  end

  test "no atom is created from a string key" do
    keys = for index <- 1..200, do: "vendor_#{System.unique_integer([:positive])}_#{index}"

    for key <- keys do
      {known, unknown} = Keys.split(%{"name" => "get", key => 1}, @keys_spec)

      assert known == %{name: "get"}
      assert Map.keys(unknown) == [key]

      assert Keys.known(%{key => 1}, @keys_spec) == %{}
      assert Keys.get(%{key => 1}, "name", :name, "d") == "d"
    end

    for key <- keys do
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end
  end
end
