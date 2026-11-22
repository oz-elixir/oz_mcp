defmodule OzMcp.Config.UseTest do
  use ExUnit.Case, async: true

  @kinds [
    {OzMcp.Config.Prompt, "def get(_ctx, _params), do: nil", "strict_names?: true"},
    {OzMcp.Config.Resource, "def read(_ctx, _params), do: nil", "strict_names?: true"},
    {OzMcp.Config.Template, "def read(_ctx, _params, _template, _vars), do: nil",
     "strict_names?: true"},
    {OzMcp.Config.Tool, "def call(_ctx, _params), do: nil", nil}
  ]

  for {kind, callback, other_option} <- @kinds do
    @kind kind
    @callback_source callback
    @other_option other_option

    describe "use #{inspect(kind)}" do
      test "an unknown option stops the compilation and names the key" do
        assert_raise ArgumentError, ~r/:dsl(?!\?)/, fn ->
          compile(@kind, "dsl: false", @callback_source)
        end
      end

      test "dynamic? is an unknown option and names the key" do
        assert_raise ArgumentError, ~r/:dynamic\?/, fn ->
          compile(@kind, "dynamic?: true", @callback_source)
        end
      end

      test "a dsl?: false module with no list/0 stops the compilation" do
        assert_raise RuntimeError, ~r/list\/0/, fn ->
          compile(@kind, "dsl?: false", @callback_source, "")
        end
      end

      if @other_option do
        test "an option of another kind stops the compilation and names the key" do
          assert_raise ArgumentError, ~r/:strict_names\?/, fn ->
            compile(@kind, @other_option, @callback_source)
          end
        end
      end
    end
  end

  describe "use OzMcp.Config.Tool, with a misspelled option" do
    test "a misspelled option stops the compilation and names the key" do
      assert_raise ArgumentError, ~r/:strict_name\?/, fn ->
        compile(OzMcp.Config.Tool, "strict_name?: true", "def call(_ctx, _params), do: nil")
      end
    end

    test "a misspelled option with warn?: false still stops the compilation" do
      assert_raise ArgumentError, ~r/:warn(?!\?)/, fn ->
        compile(
          OzMcp.Config.Tool,
          "dsl?: false, warn: true, warn?: false",
          "def call(_ctx, _params), do: nil"
        )
      end
    end
  end

  defp compile(kind, options, callback, list \\ "def list, do: []") do
    Code.compile_string("""
    defmodule OzMcp.Config.UseTest.M#{System.unique_integer([:positive])} do
      use #{inspect(kind)}, #{options}
      #{list}
      #{callback}
    end
    """)
  end
end
