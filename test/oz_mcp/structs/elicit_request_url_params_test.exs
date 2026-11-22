defmodule OzMcp.Structs.ElicitRequestURLParamsTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.{ElicitRequestURLParams, TaskMetadata}

  defp params do
    %ElicitRequestURLParams{}
    |> ElicitRequestURLParams.message("Authorize")
    |> ElicitRequestURLParams.url("https://example.com/auth?x=1")
    |> ElicitRequestURLParams.elicitation_id("e-1")
  end

  test "builds the params of a URL interaction" do
    assert ElicitRequestURLParams.build(params()) == %{
             mode: "url",
             message: "Authorize",
             url: "https://example.com/auth?x=1",
             elicitationId: "e-1"
           }
  end

  test "carries _meta" do
    result =
      params() |> ElicitRequestURLParams._meta(%{"a" => 1}) |> ElicitRequestURLParams.build()

    assert result._meta == %{"a" => 1}
  end

  test "requires message, url and elicitationId" do
    for field <- [:message, :url, :elicitationId] do
      assert_raise ArgumentError, ~r/'#{field}'/, fn ->
        params() |> Map.put(field, "") |> ElicitRequestURLParams.build()
      end
    end
  end

  test "the url must be an absolute http or https URL" do
    for url <- ["example.com", "ftp://example.com/x", "javascript:alert(1)", "https://", "/path"] do
      assert_raise ArgumentError, ~r/absolute http or https URL/, fn ->
        params() |> ElicitRequestURLParams.url(url) |> ElicitRequestURLParams.build()
      end
    end

    assert %{url: "http://localhost:4000/x"} =
             params()
             |> ElicitRequestURLParams.url("http://localhost:4000/x")
             |> ElicitRequestURLParams.build()
  end

  test "the url must not carry credentials" do
    for url <- ["https://user:pass@example.com/x", "http://user@example.com/"] do
      assert_raise ArgumentError, ~r/without credentials/, fn ->
        params() |> ElicitRequestURLParams.url(url) |> ElicitRequestURLParams.build()
      end
    end
  end

  test "sends the task metadata" do
    params = params() |> ElicitRequestURLParams.task(%TaskMetadata{ttl: 60_000})
    assert ElicitRequestURLParams.build(params).task == %{ttl: 60_000}
  end

  test "does not send task when it is nil" do
    refute Map.has_key?(ElicitRequestURLParams.build(params()), :task)
  end

  test "raises when task is not a TaskMetadata struct" do
    message = "The 'task' field must be a OzMcp.Structs.TaskMetadata struct or nil"

    assert_raise ArgumentError, message, fn ->
      ElicitRequestURLParams.build(%{params() | task: %{ttl: 1}})
    end
  end
end
