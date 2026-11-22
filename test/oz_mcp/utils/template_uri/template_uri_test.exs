defmodule OzMcp.Utils.TemplateUriTest do
  use ExUnit.Case, async: true

  alias OzMcp.Utils.TemplateUri

  # The match of a template that is a string: parsed one time here, then
  # matched with the compiled data.
  #
  defp match(template, uri) do
    TemplateUri.match_compiled(TemplateUri.compile!(template), uri)
  end

  describe "match_compiled/2 with a compiled template" do
    test "matches one expression of each operator" do
      matches = [
        {"users/{id}", "users/42", %{"id" => "42"}},
        {"r/{a,b}", "r/1,2", %{"a" => "1", "b" => "2"}},
        {"file:///{+path}", "file:///a/b.md", %{"path" => "a/b.md"}},
        {"doc{#frag}", "doc#intro", %{"frag" => "intro"}},
        {"img{.ext}", "img.png", %{"ext" => "png"}},
        {"api{/ver,id}", "api/v1/7", %{"ver" => "v1", "id" => "7"}},
        {"m{;lang,page}", "m;page=2;lang=en", %{"page" => "2", "lang" => "en"}},
        {"s{?q,n}", "s?n=5&q=a%20b", %{"n" => "5", "q" => "a b"}},
        {"s?x=1{&q}", "s?x=1&q=a", %{"q" => "a"}}
      ]

      for {template, uri, params} <- matches do
        assert {:ok, ^template, ^params} = match(template, uri),
               "#{template} against #{uri}"
      end
    end

    test "answers nil when the uri does not match" do
      assert match("users/{id}", "users/1/delete") == nil
      assert match("users/{id}", "users/") == nil
      assert match("users/{id}", "other/42") == nil
      assert match("users/{id}", "users/1%2Fdelete") == nil
    end

    test "answers nil for a uri that is not a binary" do
      compiled = TemplateUri.compile!("users/{id}")

      assert TemplateUri.match_compiled(compiled, nil) == nil
      assert TemplateUri.match_compiled(compiled, 42) == nil
    end

    test "a bad template does not compile" do
      assert {:error, _} = TemplateUri.compile("test-uri://{a")
      assert {:error, _} = TemplateUri.compile("test-uri://{a*}")
    end

    test "matches a plain literal template" do
      assert {:ok, "plain/literal", %{}} = match("plain/literal", "plain/literal")
      assert match("plain/literal", "other") == nil
    end
  end

  describe "match_compiled/2" do
    test "matches with the compiled data" do
      compiled = TemplateUri.compile!("users/{id}")

      assert {:ok, "users/{id}", %{"id" => "42"}} =
               TemplateUri.match_compiled(compiled, "users/42")

      assert TemplateUri.match_compiled(compiled, "users/1/delete") == nil
    end

    test "does not run when the uri has no literal prefix" do
      compiled = TemplateUri.compile!("users/{id}")
      assert TemplateUri.match_compiled(compiled, "other/42") == nil
    end

    test "answers nil for a uri that is not a binary" do
      compiled = TemplateUri.compile!("users/{id}")
      assert TemplateUri.match_compiled(compiled, nil) == nil
    end

    test "answers nil for data that is not a compiled template" do
      assert TemplateUri.match_compiled("not a map", "users/42") == nil
      assert TemplateUri.match_compiled(nil, "users/42") == nil
    end
  end

  describe "the size limit of the uri" do
    @max_uri_bytes 16_384

    test "a uri of 16 KiB matches a template with {+path}" do
      path = String.duplicate("a/", 8_188)
      uri = "file:///" <> path
      assert byte_size(uri) == @max_uri_bytes

      assert {:ok, "file:///{+path}", %{"path" => ^path}} =
               match("file:///{+path}", uri)
    end

    test "a uri of 16 KiB matches a template with {+path} and a literal" do
      path = String.duplicate("a/", 8_186) <> "b"
      uri = "file:///" <> path <> ".md"
      assert byte_size(uri) == @max_uri_bytes

      assert {:ok, "file:///{+path}.md", %{"path" => ^path}} =
               match("file:///{+path}.md", uri)
    end

    test "a uri over the limit gives nil and runs no walk" do
      #
      # users/{id} would match a long one-segment value, so a nil answer
      # proves that the size check runs before the walk
      #
      template = "users/{id}"
      uri = "users/" <> String.duplicate("1", 16_379)
      assert byte_size(uri) == @max_uri_bytes + 1

      assert match(template, uri) == nil

      compiled = TemplateUri.compile!(template)
      assert TemplateUri.match_compiled(compiled, uri) == nil
    end

    test "a uri at the limit still matches" do
      uri = "users/" <> String.duplicate("1", 16_378)
      assert byte_size(uri) == @max_uri_bytes

      assert {:ok, "users/{id}", %{"id" => id}} = match("users/{id}", uri)
      assert byte_size(id) == 16_378
    end
  end
end
