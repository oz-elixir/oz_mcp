defmodule OzMcpTest do
  use ExUnit.Case, async: true

  test "the moduledoc names the main modules" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(OzMcp)

    assert doc =~ "OzMcp.Config.Server"
    assert doc =~ "{OzMcp, opts}"
  end

  test "the module has no hello function" do
    refute function_exported?(OzMcp, :hello, 0)
  end
end
