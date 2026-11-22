defmodule OzMcp.Handler.OutputTest do
  use ExUnit.Case, async: true

  alias OzMcp.Handler.Output
  alias OzMcp.Structs.{CallToolResult, Tool}
  alias Support.Servers

  @server Servers.PromptsOnly

  @schema %{type: "object", properties: %{result: %{type: "string"}}}

  @required_schema %{
    type: "object",
    properties: %{result: %{type: "string"}},
    required: ["result"]
  }

  @missing "'structuredContent' is missing, the tool declares an outputSchema"
  @not_object "'structuredContent' must be an object"

  describe "schema/1" do
    test "returns the schema of a tool struct" do
      assert Output.schema(%Tool{name: "t", inputSchema: %{}, outputSchema: @schema}) == @schema
    end

    test "returns nil for a nil tool and for a tool without a schema" do
      assert Output.schema(nil) == nil
      assert Output.schema(%Tool{name: "t", inputSchema: %{}}) == nil
    end
  end

  describe "fetch_root/4" do
    test "returns {:ok, nil} when the tool declares no outputSchema" do
      assert Output.fetch_root(@server, __MODULE__, "absent", nil) == {:ok, nil}
    end

    test "builds the root of a valid schema" do
      assert {:ok, %JSV.Root{}} = Output.fetch_root(@server, __MODULE__, "valid", @schema)
    end

    test "compiles a root that the catalog does not hold" do
      assert {:ok, %JSV.Root{}} = Output.fetch_root(@server, UnknownModule, "x", @schema)
    end

    test "gives {:error, :invalid_schema} for a broken schema" do
      broken = %{"type" => "object", "properties" => %{"price" => %{"type" => "float"}}}

      assert Output.fetch_root(@server, __MODULE__, "broken", broken) == {:error, :invalid_schema}
    end
  end

  describe "check/2" do
    test "gives :ok for a nil root, whatever the result" do
      results = [
        %{structuredContent: %{"result" => "ok"}},
        %{structuredContent: [1, 2]},
        %{structuredContent: nil},
        %{},
        %{isError: true},
        %CallToolResult{},
        "a binary",
        [1, 2]
      ]

      for result <- results do
        assert Output.check(nil, result) == :ok
      end
    end

    test "gives :ok when structuredContent matches the schema" do
      {:ok, root} = Output.fetch_root(@server, __MODULE__, "match", @schema)

      assert Output.check(root, %{structuredContent: %{"result" => "ok"}}) == :ok
    end

    test "reads structuredContent from a built CallToolResult" do
      {:ok, root} = Output.fetch_root(@server, __MODULE__, "struct", @schema)

      result =
        %CallToolResult{}
        |> CallToolResult.content([])
        |> CallToolResult.structured_content(%{"result" => "ok"})
        |> CallToolResult.build()

      assert Output.check(root, result) == :ok
    end

    test "gives the violation messages when structuredContent does not match" do
      {:ok, root} = Output.fetch_root(@server, __MODULE__, "violation", @schema)

      assert Output.check(root, %{structuredContent: %{"result" => 42}}) ==
               {:error, ["'result' value is not of type string"]}
    end

    test "gives :ok for a result with isError true and no structuredContent" do
      {:ok, root} = Output.fetch_root(@server, __MODULE__, "error_no_data", @schema)

      assert Output.check(root, %{isError: true}) == :ok

      error_result =
        %CallToolResult{}
        |> CallToolResult.content([])
        |> CallToolResult.is_error(true)
        |> CallToolResult.build()

      assert Output.check(root, error_result) == :ok
    end

    test "gives :ok for a result with isError true and an incorrect structuredContent" do
      {:ok, root} = Output.fetch_root(@server, __MODULE__, "error_bad_data", @schema)

      assert Output.check(root, %{isError: true, structuredContent: %{"result" => 42}}) == :ok
    end

    test "gives the missing message when structuredContent is absent" do
      {:ok, root} = Output.fetch_root(@server, __MODULE__, "absent", @schema)

      assert Output.check(root, %{}) == {:error, [@missing]}
      assert Output.check(root, %CallToolResult{}) == {:error, [@missing]}
    end

    test "gives the missing message when structuredContent is nil" do
      {:ok, root} = Output.fetch_root(@server, __MODULE__, "nil_data", @schema)

      assert Output.check(root, %{structuredContent: nil}) == {:error, [@missing]}
    end

    test "gives the not-an-object message when structuredContent is not a map" do
      {:ok, root} = Output.fetch_root(@server, __MODULE__, "not_object", @schema)

      assert Output.check(root, %{structuredContent: [1, 2]}) == {:error, [@not_object]}
      assert Output.check(root, %{structuredContent: false}) == {:error, [@not_object]}
    end

    test "reads the atom keys of structuredContent, as the wire does" do
      {:ok, root} = Output.fetch_root(@server, __MODULE__, "atom_keys", @required_schema)

      assert Output.check(root, %{structuredContent: %{result: "ok"}}) == :ok
    end

    test "reads the atom values of structuredContent, as the wire does" do
      {:ok, root} = Output.fetch_root(@server, __MODULE__, "atom_values", @schema)

      assert Output.check(root, %{structuredContent: %{"result" => :ok}}) == :ok
    end
  end

  describe "error_result?/1" do
    test "is true for the atom key" do
      assert Output.error_result?(%{isError: true}) == true
    end

    test "is false for the other results" do
      assert Output.error_result?(%{}) == false
      assert Output.error_result?(%{isError: false}) == false
      assert Output.error_result?(%{isError: "true"}) == false
    end
  end

  describe "error/1" do
    test "gives the mismatch error with the messages as data" do
      assert Output.error(["'result' value is not of type string"]) == %{
               code: -32603,
               message: "tool output does not match outputSchema",
               data: ["'result' value is not of type string"]
             }
    end
  end
end
