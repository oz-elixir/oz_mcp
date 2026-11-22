#
# Tests for the runtime checks that the `meta/2` and `extra/2` macros call.
# See: lib/oz_mcp/config/dsl/checks.ex
#
defmodule OzMcp.Config.DSL.ChecksTest do
  use ExUnit.Case, async: true

  alias OzMcp.Config.DSL.Checks

  describe "meta_key!/1" do
    test "keeps a string key" do
      assert Checks.meta_key!("a") == "a"
    end

    test "converts an atom key to a string" do
      assert Checks.meta_key!(:a) == "a"
      assert Checks.meta_key!(:my_key) == "my_key"
    end

    test "raises ArgumentError for nil" do
      assert_raise(ArgumentError, "'key' must be a string, got: nil", fn ->
        Checks.meta_key!(nil)
      end)
    end

    test "raises ArgumentError for true" do
      assert_raise(ArgumentError, "'key' must be a string, got: true", fn ->
        Checks.meta_key!(true)
      end)
    end

    test "raises ArgumentError for false" do
      assert_raise(ArgumentError, "'key' must be a string, got: false", fn ->
        Checks.meta_key!(false)
      end)
    end

    test "raises ArgumentError for a term that is not a string or atom" do
      assert_raise(ArgumentError, "'key' must be a string, got: 1", fn ->
        Checks.meta_key!(1)
      end)
    end
  end

  describe "meta_value/1" do
    test "keeps true" do
      assert Checks.meta_value(true) == true
    end

    test "keeps false" do
      assert Checks.meta_value(false) == false
    end

    test "keeps nil" do
      assert Checks.meta_value(nil) == nil
    end

    test "converts an atom to a string" do
      assert Checks.meta_value(:foo) == "foo"
    end

    test "keeps a map" do
      assert Checks.meta_value(%{"a" => 1}) == %{"a" => 1}
    end

    test "keeps a string" do
      assert Checks.meta_value("x") == "x"
    end

    test "keeps a number" do
      assert Checks.meta_value(42) == 42
    end
  end

  describe "unique!/4" do
    test "gives :ok for a new key" do
      assert Checks.unique!([], %{name: "get_date"}, :name, "tool name") == :ok

      assert Checks.unique!([%{name: "first"}], %{name: "second"}, :name, "tool name") == :ok
    end

    test "raises for a key that is already declared" do
      assert_raise(
        ArgumentError,
        "duplicate tool name: \"get_date\" is declared two times",
        fn ->
          Checks.unique!([%{name: "get_date"}], %{name: "get_date"}, :name, "tool name")
        end
      )
    end

    test "compares only the given field" do
      assert Checks.unique!(
               [%{name: "doc", uri: "file:///a.md"}],
               %{name: "doc", uri: "file:///b.md"},
               :uri,
               "resource uri"
             ) == :ok

      assert_raise(
        ArgumentError,
        "duplicate resource uri: \"file:///a.md\" is declared two times",
        fn ->
          Checks.unique!(
            [%{name: "doc", uri: "file:///a.md"}],
            %{name: "other", uri: "file:///a.md"},
            :uri,
            "resource uri"
          )
        end
      )
    end
  end

  describe "unique_module!/3" do
    test "gives :ok for a new module" do
      assert Checks.unique_module!([], Support.Entities.Tools.SecondTest, :tools) == :ok

      assert Checks.unique_module!(
               [Support.Entities.Tools.FirstTest],
               Support.Entities.Tools.SecondTest,
               :tools
             ) == :ok
    end

    test "raises for a module that is already in the block" do
      assert_raise(
        ArgumentError,
        "module #{inspect(Support.Entities.Tools.SecondTest)} is listed two times in 'tools'",
        fn ->
          Checks.unique_module!(
            [Support.Entities.Tools.SecondTest],
            Support.Entities.Tools.SecondTest,
            :tools
          )
        end
      )

      assert_raise(
        ArgumentError,
        "module #{inspect(Support.Entities.Resources.FirstTest)} is listed two times in 'resources'",
        fn ->
          Checks.unique_module!(
            [Support.Entities.Resources.FirstTest],
            Support.Entities.Resources.FirstTest,
            :resources
          )
        end
      )
    end
  end

  describe "meta_pair_key!/2" do
    test "keeps a valid string key" do
      assert Checks.meta_pair_key!([], "region") == "region"
      assert Checks.meta_pair_key!([:tools, :list_result], "region") == "region"
    end

    test "converts an atom key to a string" do
      assert Checks.meta_pair_key!([], :region) == "region"
    end

    test "raises for a bad key" do
      assert_raise(ArgumentError, "bad _meta key \"a b\": bad name", fn ->
        Checks.meta_pair_key!([], "a b")
      end)
    end
  end

  describe "extra_pair_key!/2" do
    test "keeps a valid string key" do
      assert Checks.extra_pair_key!([], "region") == "region"
      assert Checks.extra_pair_key!([:tools, :list_result], "total") == "total"
    end

    test "converts an atom key to a string" do
      assert Checks.extra_pair_key!([], :region) == "region"
    end

    test "raises for a key that is not a string or an atom" do
      assert_raise(ArgumentError, "'key' must be a string, got: 1", fn ->
        Checks.extra_pair_key!([], 1)
      end)
    end

    test "raises for a reserved key" do
      assert_raise(ArgumentError, ~r/\"nextCursor\" is a field of the result/, fn ->
        Checks.extra_pair_key!([:tools, :list_result], "nextCursor")
      end)
    end
  end

  describe "icon!/1" do
    test "keeps an icon with a src" do
      icon = %{src: "https://a.example/i.png"}
      assert Checks.icon!(icon) == icon
    end

    test "raises for an icon with no src" do
      assert_raise(RuntimeError, "icon 'src' is required", fn ->
        Checks.icon!(%{src: ""})
      end)
    end
  end

  describe "not_empty!/3" do
    test "keeps data with one field" do
      data = %{audience: ["user"], priority: nil, lastModified: nil}

      assert Checks.not_empty!(data, [:audience, :priority, :lastModified], "annotations") ==
               data
    end

    test "raises when all the fields are nil" do
      assert_raise(RuntimeError, "remove 'annotations', it's empty", fn ->
        Checks.not_empty!(
          %{audience: nil, priority: nil, lastModified: nil},
          [
            :audience,
            :priority,
            :lastModified
          ],
          "annotations"
        )
      end)
    end
  end

  describe "modules!/2" do
    test "keeps a registry with one module" do
      data = %{modules: [Support.Entities.Tools.FirstTest]}
      assert Checks.modules!(data, "tool") == data
    end

    test "raises for an empty registry" do
      assert_raise(RuntimeError, "must declare at least one tool", fn ->
        Checks.modules!(%{modules: []}, "tool")
      end)

      assert_raise(RuntimeError, "must declare at least one resource", fn ->
        Checks.modules!(%{modules: []}, "resource")
      end)
    end
  end

  describe "required!/4" do
    test "gives :ok for a value" do
      assert Checks.required!(%{uri: "file:///a.md"}, __MODULE__, :uri, "uri is required") ==
               :ok
    end

    test "raises for an empty string" do
      assert_raise(RuntimeError, "uri is required", fn ->
        Checks.required!(%{uri: ""}, __MODULE__, :uri, "uri is required")
      end)
    end

    test "raises for nil" do
      assert_raise(RuntimeError, "uri is required", fn ->
        Checks.required!(%{uri: nil}, __MODULE__, :uri, "uri is required")
      end)
    end
  end

  describe "experimental_keys!/1" do
    test "accepts string and atom keys" do
      assert Checks.experimental_keys!(%{"a" => 1, :b => 2}) == :ok
      assert Checks.experimental_keys!(%{}) == :ok
    end

    test "raises for another key" do
      assert_raise(ArgumentError, "all keys of 'experimental' map must be a string or atom", fn ->
        Checks.experimental_keys!(%{1 => "a"})
      end)
    end
  end

  describe "extra_key!/2" do
    test "keeps a key that is not a field of the result" do
      assert Checks.extra_key!([], "region") == "region"
      assert Checks.extra_key!([:tools, :list_result], "total") == "total"
    end

    test "accepts the fields of another block" do
      assert Checks.extra_key!([:resources, :list_result], "tools") == "tools"
      assert Checks.extra_key!([:tools, :list_result], "resources") == "resources"
    end

    test "raises for a reserved key at the root" do
      assert_raise(
        ArgumentError,
        "'extra' key \"protocolVersion\" is a field of the result, " <>
          "use the field (or 'meta' for \"_meta\")",
        fn ->
          Checks.extra_key!([], "protocolVersion")
        end
      )
    end

    test "raises for a reserved key in a list_result block" do
      assert_raise(ArgumentError, ~r/\"nextCursor\" is a field of the result/, fn ->
        Checks.extra_key!([:tools, :list_result], "nextCursor")
      end)

      assert_raise(ArgumentError, ~r/\"tools\" is a field of the result/, fn ->
        Checks.extra_key!([:tools, :list_result], "tools")
      end)

      assert_raise(ArgumentError, ~r/\"resourceTemplates\" is a field of the result/, fn ->
        Checks.extra_key!([:templates, :list_result], "resourceTemplates")
      end)
    end

    test "raises for the _meta key" do
      assert_raise(
        ArgumentError,
        "'extra' key \"_meta\" is a field of the result, use the field (or 'meta' for \"_meta\")",
        fn ->
          Checks.extra_key!([], "_meta")
        end
      )
    end

    test "does not raise for a wrong path" do
      assert Checks.extra_key!([:tools], "protocolVersion") == "protocolVersion"
    end
  end
end
