#
# Tests for the value checks of a row of a DSL table.
# See: lib/oz_mcp/config/dsl/type.ex
#
defmodule OzMcp.Config.DSL.TypeTest do
  use ExUnit.Case, async: true

  alias OzMcp.Config.DSL.{Rules, Type}

  describe "simple checks" do
    test ":string keeps a binary" do
      assert Type.check!(:x, :string, "a") == "a"
      assert Type.check!(:x, :string, "") == ""
    end

    test ":string raises for a value that is not a binary" do
      assert_raise ArgumentError, "'x' must be a string, got: 1", fn ->
        Type.check!(:x, :string, 1)
      end
    end

    test ":non_empty_string keeps a non-empty binary" do
      assert Type.check!(:x, :non_empty_string, "a") == "a"
    end

    test ":non_empty_string raises for a value that is not a binary" do
      assert_raise ArgumentError, "'x' must be a string, got: nil", fn ->
        Type.check!(:x, :non_empty_string, nil)
      end
    end

    test ":non_empty_string raises for an empty binary" do
      assert_raise ArgumentError, "'x' cannot be an empty string", fn ->
        Type.check!(:x, :non_empty_string, "")
      end
    end

    test ":compact_string keeps a non-empty binary" do
      assert Type.check!(:x, :compact_string, "a") == "a"
    end

    test ":compact_string raises with one message for the two faults" do
      for value <- ["", 1, nil] do
        assert_raise ArgumentError,
                     "'x' must be a non-empty string, got: #{inspect(value)}",
                     fn -> Type.check!(:x, :compact_string, value) end
      end
    end

    test ":boolean keeps a boolean" do
      assert Type.check!(:x, :boolean, true) == true
      assert Type.check!(:x, :boolean, false) == false
    end

    test ":boolean raises for a value that is not a boolean" do
      assert_raise ArgumentError, "'x' must be a boolean, got: 1", fn ->
        Type.check!(:x, :boolean, 1)
      end
    end

    test ":module keeps an atom" do
      assert Type.check!(:x, :module, Foo.Bar) == Foo.Bar
      assert Type.check!(:x, :module, :foo) == :foo
    end

    test ":module raises for a value that is not an atom" do
      assert_raise ArgumentError, "'x' must be a module (atom), got: \"a\"", fn ->
        Type.check!(:x, :module, "a")
      end
    end

    test ":map keeps a map" do
      assert Type.check!(:x, :map, %{a: 1}) == %{a: 1}
      assert Type.check!(:x, :map, %{}) == %{}
    end

    test ":map raises for a value that is not a map" do
      assert_raise ArgumentError, "'x' must be a map, got: []", fn ->
        Type.check!(:x, :map, [])
      end
    end

    test ":number keeps a number" do
      assert Type.check!(:x, :number, 1) == 1
      assert Type.check!(:x, :number, 1.5) == 1.5
    end

    test ":number raises for a value that is not a number" do
      assert_raise ArgumentError, "'x' must be a number, got: \"1\"", fn ->
        Type.check!(:x, :number, "1")
      end
    end

    test ":non_empty_map keeps a map with entries" do
      assert Type.check!(:x, :non_empty_map, %{a: 1}) == %{a: 1}
    end

    test ":non_empty_map raises for an empty map" do
      assert_raise ArgumentError, "'x' cannot be an empty map", fn ->
        Type.check!(:x, :non_empty_map, %{})
      end
    end

    test ":empty_map keeps an empty map" do
      assert Type.check!(:x, :empty_map, %{}) == %{}
    end

    test ":empty_map raises for a map with entries" do
      assert_raise ArgumentError, "'x' must be an empty map %{}, got: %{a: 1}", fn ->
        Type.check!(:x, :empty_map, %{a: 1})
      end
    end

    test ":non_empty_list keeps a list with entries" do
      assert Type.check!(:x, :non_empty_list, ["a"]) == ["a"]
    end

    test ":non_empty_list raises for an empty list" do
      assert_raise ArgumentError, "'x' cannot be an empty list", fn ->
        Type.check!(:x, :non_empty_list, [])
      end
    end
  end

  describe "{:list, text}" do
    test "keeps a list" do
      assert Type.check!(:x, {:list, "a list"}, []) == []
      assert Type.check!(:x, {:list, "a list"}, [1]) == [1]
    end

    test "raises with the text of the row" do
      assert_raise ArgumentError, "'x' must be a list of string, got: \"a\"", fn ->
        Type.check!(:x, {:list, "a list of string"}, "a")
      end
    end
  end

  describe "{:positive_integer, text}" do
    test "keeps an integer greater than zero" do
      assert Type.check!(:x, {:positive_integer, "a positive integer (ms)"}, 1) == 1
      assert Type.check!(:x, {:positive_integer, "a positive integer (ms)"}, 10) == 10
    end

    test "raises for zero, a negative integer and a value that is not an integer" do
      for value <- [0, -1, 1.5, "1", nil] do
        assert_raise ArgumentError,
                     "'x' must be a positive integer (ms), got: #{inspect(value)}",
                     fn ->
                       Type.check!(:x, {:positive_integer, "a positive integer (ms)"}, value)
                     end
      end
    end
  end

  describe "{:one_of, values, text}" do
    test "keeps a value of the list" do
      assert Type.check!(:x, {:one_of, ["light", "dark"], "is not allowed"}, "light") == "light"
    end

    test "raises with the text after the name of the property" do
      assert_raise ArgumentError, "'x' is not allowed", fn ->
        Type.check!(:x, {:one_of, ["light", "dark"], "is not allowed"}, "dim")
      end
    end
  end

  describe "{:rule, fun}" do
    test "keeps the value when the rule gives :ok" do
      assert Type.check!(:src, {:rule, &Rules.icon_src/1}, "https://a.example/i.png") ==
               "https://a.example/i.png"
    end

    test "raises with the message of the rule after the name of the property" do
      assert_raise ArgumentError, ~r/\A'src' must be /, fn ->
        Type.check!(:src, {:rule, &Rules.icon_src/1}, "ftp://a.example/i.png")
      end
    end
  end

  describe "{:each_rule, fun}" do
    test "keeps a list when each entry gives :ok" do
      assert Type.check!(:sizes, {:each_rule, &Rules.icon_size/1}, ["48x48", "any"]) ==
               ["48x48", "any"]
    end

    test "raises with the message of an entry" do
      assert_raise ArgumentError, ~r/\A'sizes' entry must be "any" or a "WxH" string/, fn ->
        Type.check!(:sizes, {:each_rule, &Rules.icon_size/1}, ["48x48", "big"])
      end
    end
  end

  describe "{:raises, fun}" do
    test "keeps the value when the fun gives :ok" do
      assert Type.check!(:x, {:raises, fn _value -> :ok end}, "a") == "a"
    end

    test "keeps the value that the fun gives back" do
      assert Type.check!(:x, {:raises, fn value -> String.upcase(value) end}, "a") == "A"
    end

    test "keeps a changed value from a scopes check" do
      assert Type.check!(:required_scopes, {:raises, &OzMcp.Auth.Scopes.check!/1}, ["a", "a"]) ==
               ["a"]
    end

    test "lets the raise of the fun pass" do
      assert_raise ArgumentError, "'required_scopes' cannot be an empty list, remove it", fn ->
        Type.check!(:required_scopes, {:raises, &OzMcp.Auth.Scopes.check!/1}, [])
      end
    end
  end

  describe "a list of checks" do
    test "runs in order and keeps the value of the last check" do
      checks = [:string, {:raises, fn value -> value <> "!" end}]

      assert Type.check!(:x, checks, "a") == "a!"
    end

    test "stops at the first check that raises" do
      assert_raise ArgumentError, "'x' must be a string, got: 1", fn ->
        Type.check!(:x, [:string, {:raises, fn _value -> "b" end}], 1)
      end
    end
  end

  test "a table with a remote capture survives a module attribute" do
    [{mod, _}] =
      Code.compile_string("""
      defmodule TypeCaptureFixture do
        @row %{type: [{:rule, &OzMcp.Config.DSL.Rules.icon_src/1}]}
        def row, do: @row
      end
      """)

    assert Type.check!(:src, mod.row().type, "https://a.example/i.png") ==
             "https://a.example/i.png"
  end
end
