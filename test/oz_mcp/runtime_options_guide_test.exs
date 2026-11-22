Code.require_file("tools/gen_docs.exs")

defmodule OzMcp.RuntimeOptionsGuideTest do
  use ExUnit.Case, async: true

  @guide Path.join(File.cwd!(), "guides/runtime/runtime_options.md")

  test "the generated block of the options matches the code" do
    guide = File.read!(@guide)

    assert guide == OzMcpDocs.render(guide),
           "the options table is stale: run mix docs"
  end
end
