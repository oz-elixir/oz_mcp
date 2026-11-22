defmodule OzMcp.Structs.ModelPreferencesTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.ModelPreferences

  test "an empty preference builds an empty map" do
    assert ModelPreferences.build(%ModelPreferences{}) == %{}
  end

  test "builds hints and priorities" do
    result =
      %ModelPreferences{}
      |> ModelPreferences.hints(["claude", %{name: "gpt"}, %{"name" => "x"}])
      |> ModelPreferences.cost_priority(0)
      |> ModelPreferences.speed_priority(0.5)
      |> ModelPreferences.intelligence_priority(1)
      |> ModelPreferences.build()

    assert result == %{
             hints: [%{name: "claude"}, %{name: "gpt"}, %{"name" => "x"}],
             costPriority: 0,
             speedPriority: 0.5,
             intelligencePriority: 1
           }
  end

  test "priorities must be between 0 and 1" do
    for {field, setter} <- [
          costPriority: &ModelPreferences.cost_priority/2,
          speedPriority: &ModelPreferences.speed_priority/2,
          intelligencePriority: &ModelPreferences.intelligence_priority/2
        ],
        value <- [-0.1, 1.5, "high"] do
      assert_raise ArgumentError, ~r/'#{field}'/, fn ->
        %ModelPreferences{} |> setter.(value) |> ModelPreferences.build()
      end
    end
  end

  test "rejects invalid hints" do
    assert_raise ArgumentError, ~r/'hints'/, fn ->
      %ModelPreferences{} |> ModelPreferences.hints("claude") |> ModelPreferences.build()
    end

    assert_raise ArgumentError, ~r/'hints' elements/, fn ->
      %ModelPreferences{} |> ModelPreferences.hints([1]) |> ModelPreferences.build()
    end
  end
end
