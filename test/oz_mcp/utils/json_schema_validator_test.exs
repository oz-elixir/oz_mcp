defmodule OzMcp.Utils.JsonSchemaValidatorTest do
  use ExUnit.Case, async: true

  alias OzMcp.Utils.JsonSchemaValidator, as: Validator
  alias Support.Helpers.Utils

  @permissive_schema %{
    "type" => "object",
    "properties" => %{"name" => %{"type" => "string"}}
  }

  # The tests in this file share the same module, so the context key of
  # each test is unique.
  #
  defp cache_key(prefix) do
    {__MODULE__, String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")}
  end

  defp compiled_root(schema, _key) do
    assert {:ok, root} = Validator.compile(schema)
    root
  end

  describe "validate/3" do
    test "does not apply defaults by default" do
      root = compiled_root(defaults_schema(), cache_key("no_defaults"))

      assert {:ok, arguments} = Validator.validate(root, %{"name" => "Alice"})
      assert arguments == %{"name" => "Alice"}
    end

    test "does not apply defaults when explicitly disabled" do
      root = compiled_root(defaults_schema(), cache_key("defaults_false"))

      assert {:ok, arguments} =
               Validator.validate(root, %{"name" => "Alice"}, apply_defaults: false)

      assert arguments == %{"name" => "Alice"}
    end

    test "applies defaults declared in the schema when asked" do
      root = compiled_root(defaults_schema(), cache_key("defaults"))

      assert {:ok, arguments} =
               Validator.validate(root, %{"name" => "Alice"}, apply_defaults: true)

      assert arguments == %{"name" => "Alice", "role" => "user"}
    end

    test "applies defaults when arguments are absent" do
      root = compiled_root(defaults_schema(), cache_key("defaults_nil"))

      assert {:ok, arguments} = Validator.validate(root, nil, apply_defaults: true)
      assert arguments == %{"role" => "user"}
    end

    test "accepts extra properties when the schema does not forbid them" do
      root = compiled_root(@permissive_schema, cache_key("extra"))

      assert {:ok, arguments} = Validator.validate(root, %{"extra" => 1})
      assert arguments == %{"extra" => 1}
    end

    test "respects additionalProperties: false declared by the author" do
      schema = Map.put(@permissive_schema, "additionalProperties", false)
      root = compiled_root(schema, cache_key("strict"))

      assert {:error, errors} = Validator.validate(root, %{"name" => "a", "extra" => 1})
      assert errors == ["additional properties are not allowed but found property 'extra'"]
    end

    test "reports required, type and constraint errors" do
      schema = %{
        "type" => "object",
        "required" => ["age"],
        "properties" => %{"age" => %{"type" => "integer", "minimum" => 0}}
      }

      root = compiled_root(schema, cache_key("constraints"))

      assert {:error, errors} = Validator.validate(root, %{"age" => -1})
      assert errors == ["'age' value -1 is lower than minimum 0"]

      assert {:error, errors} = Validator.validate(root, %{})
      assert errors == ["property 'age' is required"]
    end

    test "rejects a non-object payload" do
      root = compiled_root(@permissive_schema, cache_key("payload"))

      assert {:error, errors} = Validator.validate(root, "not-a-map")
      assert errors == ["value is not of type object"]
    end

    test "accepts atom-keyed schemas and arguments" do
      schema = %{type: "object", properties: %{name: %{type: "string"}}}
      root = compiled_root(schema, cache_key("atoms"))

      assert {:ok, arguments} = Validator.validate(root, %{name: "Alice"})
      assert arguments == %{name: "Alice"}
    end

    test "repeated validations with the same root stay consistent" do
      #
      # The compiled root is reused on the second call, so results must
      # stay identical (extra properties accepted, declared properties
      # still checked).
      #
      root = compiled_root(@permissive_schema, cache_key("consistent"))

      assert {:ok, _} = Validator.validate(root, %{"extra" => 1})
      assert {:ok, _} = Validator.validate(root, %{"extra" => 1})

      assert {:error, errors} = Validator.validate(root, %{"name" => 1})
      assert errors == ["'name' value is not of type string"]

      assert {:error, errors} = Validator.validate(root, %{"name" => 1})
      assert errors == ["'name' value is not of type string"]
    end

    test "validates data matching the schema" do
      schema = %{"type" => "object", "properties" => %{"result" => %{"type" => "string"}}}

      assert {:ok, root} = Validator.compile(schema)

      assert {:ok, data} = Validator.validate(root, %{"result" => "ok", "extra" => true})
      assert data == %{"result" => "ok", "extra" => true}
    end

    test "rejects data that does not match the schema" do
      schema = %{"type" => "object", "properties" => %{"result" => %{"type" => "string"}}}

      assert {:ok, root} = Validator.compile(schema)

      assert {:error, errors} = Validator.validate(root, %{"result" => 42})
      assert errors == ["'result' value is not of type string"]
    end

    test "reuses the compiled root across calls" do
      schema = %{"type" => "object", "properties" => %{"result" => %{"type" => "string"}}}

      assert {:ok, root} = Validator.compile(schema)

      assert {:ok, _} = Validator.validate(root, %{"result" => "first"})
      assert {:ok, _} = Validator.validate(root, %{"result" => "second"})
    end

    test "a pattern that exhausts its backtracking budget gives an error, not a crash" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string", "pattern" => "^(a+)+$"}}
      }

      root = compiled_root(schema, cache_key("indeterminate"))
      data = %{"name" => String.duplicate("a", 64) <> "!"}

      assert {:error, [message | _]} = Validator.validate(root, data)
      assert is_binary(message)
    end

    test "counts minLength and maxLength in code points" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string", "minLength" => 2, "maxLength" => 2}}
      }

      root = compiled_root(schema, cache_key("code_points"))

      # One grapheme, two code points.
      #
      assert {:ok, _} = Validator.validate(root, %{"name" => "e\u0301"})
      assert {:error, _} = Validator.validate(root, %{"name" => "e"})
    end
  end

  describe "validate_schema/2" do
    @schema %{
      "type" => "object",
      "properties" => %{"age" => %{"type" => "integer", "minimum" => 0}},
      "required" => ["age"]
    }

    test "returns the data that matches the schema" do
      assert Validator.validate_schema(@schema, %{"age" => 3}) == {:ok, %{"age" => 3}}
    end

    test "returns the messages of the data that does not match" do
      assert {:error, [_ | _] = messages} = Validator.validate_schema(@schema, %{"age" => -1})
      assert Enum.all?(messages, &is_binary/1)
      assert {:error, [_ | _]} = Validator.validate_schema(@schema, %{})
    end

    test "accepts a schema with atom keys" do
      schema = %{type: "object", properties: %{ok: %{type: "boolean"}}}

      assert {:ok, _} = Validator.validate_schema(schema, %{"ok" => true})
      assert {:error, [_ | _]} = Validator.validate_schema(schema, %{"ok" => "yes"})
    end

    test "reports a schema that cannot be built" do
      assert Validator.validate_schema(%{"type" => "nonsense"}, %{}) == {:error, :invalid_schema}
    end
  end

  describe "check_validate!/2" do
    test "returns :ok and writes no cache" do
      key = cache_key("check_ok")
      assert :ok = Validator.check_validate!(key, @permissive_schema)
      assert :persistent_term.get(key, :missing) == :missing
    end

    test "raises ArgumentError when the schema is invalid" do
      key = cache_key("check_bad")
      schema = %{"type" => "object", "properties" => %{"price" => %{"type" => "float"}}}

      assert_raise ArgumentError,
                   ~r"invalid schema for key #{Regex.escape(inspect(key))}",
                   fn ->
                     Validator.check_validate!(key, schema)
                   end
    end
  end

  describe "compile/1" do
    test "builds a root and logs nothing" do
      log =
        Utils.capture_log(fn ->
          assert {:ok, %JSV.Root{}} = Validator.compile(@permissive_schema)
        end)

      assert log == ""
    end

    test "gives the reason of an invalid schema and logs nothing" do
      schema = %{"type" => "object", "properties" => %{"price" => %{"type" => "float"}}}

      log =
        Utils.capture_log(fn ->
          assert {:error, reason} = Validator.compile(schema)
          refute is_nil(reason)
        end)

      assert log == ""
    end
  end

  defp defaults_schema do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "role" => %{"type" => "string", "default" => "user"}
      }
    }
  end
end
