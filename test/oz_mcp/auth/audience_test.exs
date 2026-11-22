defmodule OzMcp.Auth.AudienceTest do
  use ExUnit.Case, async: true

  alias OzMcp.Auth.Audience

  describe "canonical/1" do
    test "gives the canonical form of an upper-case scheme and host" do
      assert Audience.canonical("HTTPS://MCP.Example.Com/mcp") ==
               {:ok, "https://mcp.example.com/mcp"}
    end

    test "removes the default port of the scheme" do
      assert Audience.canonical("https://mcp.example.com:443/mcp") ==
               {:ok, "https://mcp.example.com/mcp"}

      assert Audience.canonical("http://localhost:80/api") ==
               {:ok, "http://localhost/api"}
    end

    test "keeps a port that is not the default of the scheme" do
      assert Audience.canonical("https://mcp.example.com:8443/mcp") ==
               {:ok, "https://mcp.example.com:8443/mcp"}
    end

    test "the path `/` and the empty path give the same canonical form" do
      assert Audience.canonical("https://mcp.example.com/") == {:ok, "https://mcp.example.com"}
      assert Audience.canonical("https://mcp.example.com") == {:ok, "https://mcp.example.com"}
    end

    test "keeps the case of the path" do
      assert Audience.canonical("https://mcp.example.com/Mcp") ==
               {:ok, "https://mcp.example.com/Mcp"}
    end

    test "gives :error for a value without a host" do
      for url <- ["/mcp", "mcp.example.com/mcp", "https:///mcp"] do
        assert Audience.canonical(url) == :error
      end
    end

    test "gives :error for a value that is not a string" do
      for value <- [nil, 42, :mcp, [], %URI{}] do
        assert Audience.canonical(value) == :error
      end
    end
  end

  describe "member?/2" do
    @resource_url "https://mcp.example.com/mcp"

    test "gives false for nil, an empty list and a value that is not a list" do
      refute Audience.member?(nil, @resource_url)
      refute Audience.member?([], @resource_url)
      refute Audience.member?(@resource_url, @resource_url)
    end

    test "gives true when one entry of the list is the resource URL" do
      assert Audience.member?([@resource_url], @resource_url)
      assert Audience.member?(["https://other.example.com/mcp", @resource_url], @resource_url)
    end

    test "the compare is insensitive to the case of the scheme and the host" do
      assert Audience.member?(["HTTPS://MCP.EXAMPLE.COM/mcp"], @resource_url)
      assert Audience.member?([@resource_url], "HTTPS://MCP.Example.Com/mcp")
    end

    test "gives false for a list without the resource URL" do
      refute Audience.member?(["https://other.example.com/mcp"], @resource_url)
      refute Audience.member?(["https://mcp.example.com/other"], @resource_url)
    end

    test "gives false when no entry of the list is a string that identifies the URL" do
      refute Audience.member?([42], @resource_url)
      refute Audience.member?([nil], @resource_url)

      refute Audience.member?(
               ["https://mcp.example.com/mcp", 42],
               "https://other.example.com/mcp"
             )
    end

    test "gives false when the resource URL is not canonicalizable" do
      refute Audience.member?([@resource_url], "/mcp")
      refute Audience.member?([@resource_url], nil)
    end
  end
end
