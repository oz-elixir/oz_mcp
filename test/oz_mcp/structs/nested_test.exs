defmodule OzMcp.Structs.NestedTest do
  use ExUnit.Case, async: true

  alias OzMcp.Structs.Nested

  alias OzMcp.Structs.{Annotations, Icon}

  describe "convert/3, the entity mode" do
    test "a nil value passes" do
      assert Nested.convert({:struct, Annotations}, nil, "annotations") == {:ok, nil}
    end

    test "a map becomes its struct, with atom keys and with string keys" do
      assert Nested.convert({:struct, Annotations}, %{priority: 0.5}, "annotations") ==
               {:ok, %Annotations{priority: 0.5}}

      assert Nested.convert({:struct, Annotations}, %{"priority" => 0.5}, "annotations") ==
               {:ok, %Annotations{priority: 0.5}}
    end

    test "a struct passes" do
      struct = %Annotations{priority: 0.5}
      assert Nested.convert({:struct, Annotations}, struct, "annotations") == {:ok, struct}
    end

    test "a struct of another kind is an error that names the path" do
      assert {:error, reason} = Nested.convert({:struct, Annotations}, %Icon{}, "annotations")
      assert reason =~ "annotations must be a OzMcp.Structs.Annotations"
    end

    test "a value that is not a map is an error" do
      assert {:error, reason} = Nested.convert({:struct, Annotations}, 1, "annotations")
      assert reason =~ "annotations must be a map or a OzMcp.Structs.Annotations"
    end

    test "an unknown key is an error that names the path" do
      assert {:error, reason} =
               Nested.convert({:struct, Annotations}, %{priority: 0.5, custom: 1}, "annotations")

      assert reason == "annotations.custom is not a field of OzMcp.Structs.Annotations"
    end

    test "a list of maps becomes a list of structs, with the index in the path" do
      assert Nested.convert({:list_of, Icon}, [%{src: "https://x/i.png"}], "icons") ==
               {:ok, [%Icon{src: "https://x/i.png"}]}

      assert {:error, reason} =
               Nested.convert({:list_of, Icon}, [%{src: "https://x/i.png", custom: 1}], "icons")

      assert reason == "icons[0].custom is not a field of OzMcp.Structs.Icon"
    end

    test "an improper list and a value that is not a list are errors" do
      assert {:error, "icons must be a list"} = Nested.convert({:list_of, Icon}, [1 | 2], "icons")
      assert {:error, "icons must be a list"} = Nested.convert({:list_of, Icon}, 1, "icons")
    end

    test "another spec passes the value as it is" do
      assert Nested.convert({:any, []}, %{a: 1}, "a") == {:ok, %{a: 1}}
    end
  end

  describe "icons/1, the result mode" do
    test "a list of maps becomes a list of Icon structs, an unknown key is dropped" do
      assert Nested.icons([%{src: "https://x/i.png", custom: 1}]) ==
               {:ok, [%Icon{src: "https://x/i.png"}]}
    end

    test "an icon struct passes, a nil passes" do
      icon = %Icon{src: "https://x/i.png"}
      assert Nested.icons([icon]) == {:ok, [icon]}
      assert Nested.icons(nil) == {:ok, nil}
    end

    test "an icon of the wrong kind is an error that names the path" do
      assert {:error, reason} = Nested.icons([%Annotations{}])
      assert reason =~ "icons[0] must be a OzMcp.Structs.Icon"
    end

    test "an improper list and a value that is not a list are errors" do
      assert {:error, "icons must be a list"} = Nested.icons([1 | 2])
      assert {:error, "icons must be a list"} = Nested.icons(1)
    end
  end
end
