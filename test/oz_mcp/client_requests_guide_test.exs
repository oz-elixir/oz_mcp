defmodule OzMcp.ClientRequestsGuideTest do
  use ExUnit.Case, async: true

  @guide Path.join(File.cwd!(), "guides/runtime/client_requests.md")

  test "the client task section gives an example that compiles" do
    body = raw_section_after(File.read!(@guide), "## Run a request as a task of the client")

    assert [code] = Regex.run(~r/```elixir\n(.*?)```/s, body, capture: :all_but_first)

    assert code =~ "OzMcp.Client.sample(ctx, messages"
    assert code =~ "task: %{ttl: 600_000}"
    assert code =~ "timeout: 600_000"

    source = """
    defmodule OzMcp.ClientRequestsGuideTest.TaskExample do
      def call(ctx, messages) do
    #{code}
      end

      defp summarize(content), do: content
    end
    """

    [{module, _binary} | _] = Code.compile_string(source)

    try do
      assert function_exported?(module, :call, 2)
    after
      :code.purge(module)
      :code.delete(module)
    end
  end

  # The body of one section, with the line ends. The tests of the code
  # examples need them.
  #
  defp raw_section_after(guide, title) do
    [_before, rest] = String.split(guide, title, parts: 2)

    case String.split(rest, "\n## ", parts: 2) do
      [body] -> body
      [body, _after] -> body
    end
  end
end
