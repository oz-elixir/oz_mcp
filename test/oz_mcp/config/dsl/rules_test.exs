#
# Tests for the shared rules that the DSL macros and the entity structs
# call to validate their values.
# See: lib/oz_mcp/config/dsl/rules.ex
#
defmodule OzMcp.Config.DSL.RulesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias OzMcp.Config.DSL.Rules

  describe "tool_name/1" do
    test "accepts 128 characters" do
      assert Rules.tool_name(String.duplicate("a", 128)) == :ok
    end

    test "refuses 129 characters" do
      name = String.duplicate("a", 129)

      assert Rules.tool_name(name) ==
               {:error,
                "must be 1 to 128 characters of A-Z, a-z, 0-9, _, - and ., got: #{inspect(name)}"}
    end

    test "accepts letters, digits, _ - and ." do
      assert Rules.tool_name("get_date-1.v2") == :ok
    end

    test "refuses a name with a space" do
      assert Rules.tool_name("a b") ==
               {:error, "must be 1 to 128 characters of A-Z, a-z, 0-9, _, - and ., got: \"a b\""}
    end

    test "refuses a name with an accent" do
      assert Rules.tool_name("é") ==
               {:error, "must be 1 to 128 characters of A-Z, a-z, 0-9, _, - and ., got: \"é\""}
    end

    test "refuses a name with a newline" do
      assert Rules.tool_name("name\n") ==
               {:error,
                "must be 1 to 128 characters of A-Z, a-z, 0-9, _, - and ., got: \"name\\n\""}
    end

    test "refuses the empty string" do
      assert Rules.tool_name("") ==
               {:error, "must be 1 to 128 characters of A-Z, a-z, 0-9, _, - and ., got: \"\""}
    end

    test "refuses a value that is not a string" do
      assert Rules.tool_name(42) ==
               {:error, "must be 1 to 128 characters of A-Z, a-z, 0-9, _, - and ., got: 42"}

      assert Rules.tool_name(nil) ==
               {:error, "must be 1 to 128 characters of A-Z, a-z, 0-9, _, - and ., got: nil"}
    end
  end

  describe "object_schema/1" do
    test "accepts a string key with a string value" do
      assert Rules.object_schema(%{"type" => "object"}) == :ok
    end

    test "accepts an atom key with an atom value" do
      assert Rules.object_schema(%{type: :object}) == :ok
    end

    test "accepts an atom key with a string value" do
      assert Rules.object_schema(%{type: "object"}) == :ok
    end

    test "refuses another type" do
      assert Rules.object_schema(%{type: "string"}) ==
               {:error, ~s(the root must have type: "object", got: "string")}
    end

    test "refuses an empty map" do
      assert Rules.object_schema(%{}) ==
               {:error, ~s(the root must have type: "object", got: nil)}
    end

    test "refuses a map with another key only" do
      assert Rules.object_schema(%{"$ref" => "#/x"}) ==
               {:error, ~s(the root must have type: "object", got: nil)}
    end

    test "refuses a value that is not a map" do
      assert Rules.object_schema("object") == {:error, ~s(must be a map, got: "object")}
      assert Rules.object_schema(nil) == {:error, "must be a map, got: nil"}
    end
  end

  describe "iso8601/1" do
    test "accepts a UTC offset" do
      assert Rules.iso8601("2025-01-12T15:00:58Z") == :ok
    end

    test "accepts a numeric offset" do
      assert Rules.iso8601("2025-01-12T15:00:58+02:00") == :ok
    end

    test "refuses a date with no time" do
      assert Rules.iso8601("2025-01-12") ==
               {:error,
                ~s(must be an ISO 8601 date and time with an offset, for example "2025-01-12T15:00:58Z", got: "2025-01-12")}
    end

    test "refuses a time with no offset" do
      assert Rules.iso8601("2025-01-12T15:00:58") ==
               {:error,
                ~s(must be an ISO 8601 date and time with an offset, for example "2025-01-12T15:00:58Z", got: "2025-01-12T15:00:58")}
    end

    test "refuses a word" do
      assert Rules.iso8601("yesterday") ==
               {:error,
                ~s(must be an ISO 8601 date and time with an offset, for example "2025-01-12T15:00:58Z", got: "yesterday")}
    end

    test "refuses a value that is not a string" do
      assert Rules.iso8601(42) ==
               {:error,
                ~s(must be an ISO 8601 date and time with an offset, for example "2025-01-12T15:00:58Z", got: 42)}

      assert Rules.iso8601(nil) ==
               {:error,
                ~s(must be an ISO 8601 date and time with an offset, for example "2025-01-12T15:00:58Z", got: nil)}
    end
  end

  describe "absolute_uri/1" do
    test "accepts a file URI" do
      assert Rules.absolute_uri("file:///a") == :ok
    end

    test "accepts a custom scheme" do
      assert Rules.absolute_uri("myapp://notes/1") == :ok
    end

    test "accepts an http URI" do
      assert Rules.absolute_uri("https://a.com/x") == :ok
    end

    test "refuses a value with no scheme" do
      assert Rules.absolute_uri("hello") ==
               {:error, "must be an absolute URI with a scheme, got: \"hello\""}
    end

    test "refuses a value that is not a string" do
      assert Rules.absolute_uri(42) ==
               {:error, "must be an absolute URI with a scheme, got: 42"}

      assert Rules.absolute_uri(nil) ==
               {:error, "must be an absolute URI with a scheme, got: nil"}
    end

    test "agrees with URI.new/1 on the edge cases" do
      inputs = [
        "file:///a<b",
        "file:///a\"b",
        "file:///{",
        "file:///a|b",
        "file:///a\\b",
        "file:///a^b",
        "file:///a`b",
        "file:///a\nb",
        "file:///a\tb",
        "file:///é",
        "file:///a#b#c",
        "http://[::1",
        "http://h:abc/x",
        "a://@@/x",
        "http://a:b:c/x",
        "http://a@b@c/x",
        "http://h:8080/x",
        "mailto:a@b.c",
        "urn:isbn:123",
        "file:///a%zz",
        "a:b"
      ]

      for value <- inputs do
        assert rule_ok?(value) == uri_ok?(value), "disagreement for #{inspect(value)}"
      end
    end

    property "agrees with URI.new/1 on the random inputs" do
      check all value <- uri_string() do
        assert rule_ok?(value) == uri_ok?(value), "disagreement for #{inspect(value)}"
      end
    end
  end

  describe "icon_src/1" do
    test "accepts https with a host in any case" do
      assert Rules.icon_src("HTTPS://a.com/a.png") == :ok
    end

    test "refuses https with no host" do
      assert Rules.icon_src("https://") ==
               {:error,
                "must be an https: URL, an http: URL of a loopback host, or a data: URI, got: \"https://\""}
    end

    test "accepts http for localhost" do
      assert Rules.icon_src("http://localhost:4000/a.png") == :ok
    end

    test "accepts http for ::1" do
      assert Rules.icon_src("http://[::1]:4000/a.png") == :ok
    end

    test "refuses http for a host that only starts with localhost" do
      assert Rules.icon_src("http://localhost.example.com/a.png") ==
               {:error,
                "must be an https: URL, an http: URL of a loopback host, or a data: URI, got: \"http://localhost.example.com/a.png\""}
    end

    test "refuses http for a public host" do
      assert Rules.icon_src("http://example.com/a.png") ==
               {:error,
                "must be an https: URL, an http: URL of a loopback host, or a data: URI, got: \"http://example.com/a.png\""}
    end

    test "accepts a data URI with a comma" do
      assert Rules.icon_src("data:image/png;base64,AAAA") == :ok
    end

    test "refuses a data URI with no comma" do
      assert Rules.icon_src("data:image/png") ==
               {:error,
                "must be an https: URL, an http: URL of a loopback host, or a data: URI, got: \"data:image/png\""}
    end

    test "refuses a scheme that is not allowed" do
      assert Rules.icon_src("javascript:alert(1)") ==
               {:error,
                "must be an https: URL, an http: URL of a loopback host, or a data: URI, got: \"javascript:alert(1)\""}
    end

    test "refuses a relative path" do
      assert Rules.icon_src("/icons/a.png") ==
               {:error,
                "must be an https: URL, an http: URL of a loopback host, or a data: URI, got: \"/icons/a.png\""}
    end

    test "refuses a value that is not a string" do
      assert Rules.icon_src(42) ==
               {:error,
                "must be an https: URL, an http: URL of a loopback host, or a data: URI, got: 42"}

      assert Rules.icon_src(nil) ==
               {:error,
                "must be an https: URL, an http: URL of a loopback host, or a data: URI, got: nil"}
    end
  end

  describe "icon_size/1" do
    test "accepts a WxH string" do
      assert Rules.icon_size("48x48") == :ok
    end

    test "accepts any" do
      assert Rules.icon_size("any") == :ok
    end

    test "refuses a zero size" do
      assert Rules.icon_size("0x0") ==
               {:error, ~s(must be "any" or a "WxH" string such as "48x48", got: "0x0")}
    end

    test "refuses a width only" do
      assert Rules.icon_size("48") ==
               {:error, ~s(must be "any" or a "WxH" string such as "48x48", got: "48")}
    end

    test "refuses a value that is not a string" do
      assert Rules.icon_size(48) ==
               {:error, ~s(must be "any" or a "WxH" string such as "48x48", got: 48)}

      assert Rules.icon_size(nil) ==
               {:error, ~s(must be "any" or a "WxH" string such as "48x48", got: nil)}
    end
  end

  describe "resource_size/1" do
    test "accepts a positive integer" do
      assert Rules.resource_size(1) == :ok
      assert Rules.resource_size(2048) == :ok
    end

    test "refuses a value that is not an integer" do
      assert Rules.resource_size("12") == {:error, ~s(must be an integer, got: "12")}
      assert Rules.resource_size(nil) == {:error, "must be an integer, got: nil"}
      assert Rules.resource_size(1.5) == {:error, "must be an integer, got: 1.5"}
    end

    test "refuses zero" do
      assert Rules.resource_size(0) == {:error, "cannot be equals to zero"}
    end

    test "refuses a negative integer" do
      assert Rules.resource_size(-1) == {:error, "must be a positive integer"}
    end
  end

  describe "audience/1" do
    test "accepts the two roles" do
      assert Rules.audience(["user"]) == :ok
      assert Rules.audience(["user", "assistant"]) == :ok
      assert Rules.audience(["assistant", "user"]) == :ok
    end

    test "refuses a value that is not a list" do
      assert Rules.audience("user") == {:error, ~s(must be a list, got: "user")}
      assert Rules.audience(nil) == {:error, "must be a list, got: nil"}
    end

    test "refuses an empty list" do
      assert Rules.audience([]) == {:error, "cannot be an empty list"}
    end

    test "refuses an unknown role" do
      assert Rules.audience(["admin"]) ==
               {:error, ~s(elements must be "user" or "assistant", got: ["admin"])}

      assert Rules.audience(["user", :assistant]) ==
               {:error, ~s(elements must be "user" or "assistant", got: ["user", :assistant])}
    end

    test "refuses a duplicate role" do
      assert Rules.audience(["user", "user"]) ==
               {:error, ~s(has duplicates elements, got: ["user", "user"])}
    end
  end

  describe "protocol_version/1" do
    test "accepts each supported version" do
      for version <- OzMcp.Protocol.supported() do
        assert Rules.protocol_version(version) == :ok
      end
    end

    test "refuses an unsupported version" do
      supported = OzMcp.Protocol.supported()

      assert Rules.protocol_version("1999-01-01") ==
               {:error, "must be one of #{inspect(supported)}, got: \"1999-01-01\""}
    end

    test "refuses a value that is not a string" do
      supported = OzMcp.Protocol.supported()

      assert Rules.protocol_version(nil) ==
               {:error, "must be one of #{inspect(supported)}, got: nil"}
    end
  end

  describe "meta_key/1" do
    test "format of a _meta key" do
      valid = [
        "",
        "a",
        :a,
        "my-key",
        "com.example/",
        "com.example/key",
        "com.example/a.b_c",
        "mcp/x"
      ]

      for key <- valid do
        assert :ok = Rules.meta_key(key)
      end

      for key <- [
            "/x",
            "a b",
            "-a",
            "a-",
            "1com/x",
            "com..example/x",
            "com.example/-x",
            "a/b/c",
            1
          ] do
        assert {:error, _} = Rules.meta_key(key)
      end
    end

    test "accepts the keys that the framework writes" do
      assert :ok = Rules.meta_key("io.modelcontextprotocol/related-task")
      assert :ok = Rules.meta_key("io.modelcontextprotocol/model-immediate-response")
    end

    test "accepts a name with underscores, dots and hyphens" do
      assert :ok = Rules.meta_key("my_key.name-2")
    end

    test "refuses a reserved prefix" do
      reserved = [
        "io.modelcontextprotocol/x",
        "dev.mcp/x",
        "org.modelcontextprotocol.api/x",
        "com.mcp.tools/x"
      ]

      for key <- reserved do
        assert {:error, "the _meta prefix of " <> _} = Rules.meta_key(key)
      end
    end

    test "does not reserve a prefix whose second label only holds the letters" do
      assert :ok = Rules.meta_key("com.example.mcp/x")
    end

    test "refuses a value that is not a string or an atom" do
      assert {:error, "bad _meta key 1: not a string"} = Rules.meta_key(1)
      assert {:error, "bad _meta key nil: not a string"} = Rules.meta_key(nil)
      assert {:error, "bad _meta key true: not a string"} = Rules.meta_key(true)
    end
  end

  describe "meta_keys/1" do
    test "accepts nil" do
      assert Rules.meta_keys(nil) == :ok
    end

    test "accepts a map with valid keys" do
      assert Rules.meta_keys(%{"key" => "value", :other => 1}) == :ok
    end

    test "accepts the empty map" do
      assert Rules.meta_keys(%{}) == :ok
    end

    test "refuses a map with a bad key" do
      assert {:error, "bad _meta key \"a b\": bad name"} = Rules.meta_keys(%{"a b" => 1})
    end

    test "refuses a map with a reserved prefix" do
      assert {:error, "the _meta prefix of \"dev.mcp/x\" is reserved"} =
               Rules.meta_keys(%{"dev.mcp/x" => 1})
    end

    test "refuses a value that is not a map" do
      assert Rules.meta_keys("key") == {:error, "must be a map"}
      assert Rules.meta_keys(12) == {:error, "must be a map"}
    end
  end

  defp rule_ok?(value), do: Rules.absolute_uri(value) == :ok

  defp uri_ok?(value) do
    match?({:ok, %URI{scheme: scheme}} when is_binary(scheme), URI.new(value))
  end

  defp uri_string do
    gen all scheme <-
              StreamData.member_of([
                "a",
                "http",
                "file",
                "mailto",
                "bench-res-check",
                "A+b-c.d",
                nil
              ]),
            rest <- StreamData.one_of([mixed_bytes(), safe_bytes()]) do
      if scheme, do: scheme <> ":" <> rest, else: rest
    end
  end

  defp mixed_bytes do
    StreamData.string(~c"abcxyzABCXYZ0123456789-._~!$&'()*+,;=/?:@%<>\"{}|\\^\n\t#[]é ",
      max_length: 16
    )
  end

  defp safe_bytes do
    StreamData.string(~c"abcxyzABCXYZ0123456789-._~!$&'()*+,;=/?:@%", max_length: 16)
  end
end
