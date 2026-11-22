defmodule OzMcp.Utils.TemplateUri.MatcherTest do
  use ExUnit.Case, async: true

  alias OzMcp.Utils.TemplateUri
  alias OzMcp.Utils.TemplateUri.Matcher

  defp match(template, uri) do
    template |> TemplateUri.compile!() |> Matcher.run(uri)
  end

  describe "one expression of each operator" do
    test "matches the reference examples" do
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
        assert {:ok, ^params} = match(template, uri), "#{template} against #{uri}"
      end
    end

    test "matches a plain literal template" do
      assert {:ok, %{}} = match("plain/literal", "plain/literal")
      assert match("plain/literal", "other") == :nomatch
    end
  end

  describe "a simple variable" do
    test "does not cross '/', '?' or '#'" do
      assert match("users/{id}", "users/1/delete") == :nomatch
      assert match("users/{id}", "users/1?x") == :nomatch
      assert match("users/{id}", "users/1#x") == :nomatch
    end

    test "does not match an empty value" do
      assert match("users/{id}", "users/") == :nomatch
    end

    test "does not hold a decoded '/'" do
      assert match("users/{id}", "users/1%2Fdelete") == :nomatch
    end

    test "in a list, each value stops at ','" do
      assert {:ok, %{"a" => "1", "b" => "2"}} = match("r/{a,b}", "r/1,2")
      assert match("r/{a,b}", "r/1,2,3") == :nomatch
    end
  end

  describe "a reserved expression {+var}" do
    test "crosses '/' and '?'" do
      assert {:ok, %{"path" => "a/b"}} = match("{+path}", "a/b")
      assert {:ok, %{"path" => "a/b?c=1"}} = match("{+path}", "a/b?c=1")
    end

    test "decodes '%2F'" do
      assert {:ok, %{"path" => "a/b"}} = match("{+path}", "a%2Fb")
    end

    test "does not cross '#'" do
      assert match("{+path}", "a#b") == :nomatch
    end

    test "in a list, each value stops at ','" do
      assert {:ok, %{"a" => "x/y", "b" => "z"}} = match("{+a,b}", "x/y,z")
      assert match("{+a,b}", "x,y,z") == :nomatch
    end
  end

  describe "the decode of the values" do
    test "decodes '%20' and a UTF-8 sequence" do
      assert {:ok, %{"v" => "a b"}} = match("x/{v}", "x/a%20b")
      assert {:ok, %{"v" => "é"}} = match("x/{v}", "x/%C3%A9")
    end

    test "a bad triplet gives no match" do
      assert match("x/{v}", "x/%zz") == :nomatch
      assert match("x/{v}", "x/%4") == :nomatch
    end

    test "a value that is not valid UTF-8 after the decode gives no match" do
      assert match("x/{v}", "x/%FF") == :nomatch
    end

    test "a '+' stays a '+'" do
      assert {:ok, %{"v" => "a+b"}} = match("x/{v}", "x/a+b")
    end
  end

  describe "a query expression {?...}" do
    test "the names come in any order" do
      assert {:ok, %{"q" => "x", "n" => "5"}} = match("s{?q,n}", "s?q=x&n=5")
      assert {:ok, %{"q" => "x", "n" => "5"}} = match("s{?q,n}", "s?n=5&q=x")
    end

    test "an absent variable has no key" do
      assert {:ok, %{"q" => "x"}} = match("s{?q,n}", "s?q=x")
    end

    test "an absent expression matches" do
      assert {:ok, %{}} = match("s{?q,n}", "s")
    end

    test "a repeated known name gives no match" do
      assert match("s{?q,n}", "s?q=a&q=b") == :nomatch
    end

    test "an unknown name is ignored, two times too" do
      assert {:ok, %{}} = match("s{?q,n}", "s?z=1")
      assert {:ok, %{}} = match("s{?q,n}", "s?z=1&z=2")
    end

    test "a pair with no '=' gives an empty value" do
      assert {:ok, %{"q" => ""}} = match("s{?q}", "s?q=")
      assert {:ok, %{"q" => ""}} = match("s{?q}", "s?q")
    end

    test "the name is compared after the decode" do
      assert {:ok, %{"q" => "1"}} = match("s{?q}", "s?%71=1")
    end

    test "a known name with a bad value gives no match, an unknown name is ignored" do
      assert match("s{?q}", "s?q=%zz") == :nomatch
      assert {:ok, %{}} = match("s{?q}", "s?z=%zz")
    end

    test "the expression reads the remainder up to '#'" do
      assert {:ok, %{"q" => "1", "f" => "intro"}} = match("s{?q}{#f}", "s?q=1#intro")
      assert match("s{?q}", "s?q=1#intro") == :nomatch
    end
  end

  describe "a continuation expression {&...}" do
    test "reads the pairs after the fixed query" do
      assert {:ok, %{"q" => "a", "n" => "2"}} = match("s?x=1{&q,n}", "s?x=1&q=a&n=2")
    end

    test "an absent expression matches" do
      assert {:ok, %{}} = match("s?x=1{&q}", "s?x=1")
    end
  end

  describe "a label, a path and a param expression" do
    test "{.ext} matches one label" do
      assert {:ok, %{"ext" => "png"}} = match("img{.ext}", "img.png")
      assert match("img{.ext}", "img.") == :nomatch
      assert match("img{.ext}", "img") == :nomatch
    end

    test "{/a,b} matches one segment for each variable" do
      assert {:ok, %{"x" => "a", "y" => "b"}} = match("h{/x,y}", "h/a/b")
      assert match("h{/x,y}", "h/a") == :nomatch
      assert match("h{/x}", "h") == :nomatch
    end

    test "{;...} takes the pairs in any order" do
      assert {:ok, %{"lang" => "en", "page" => "2"}} = match("m{;lang,page}", "m;lang=en;page=2")
      assert {:ok, %{"lang" => "en", "page" => "2"}} = match("m{;lang,page}", "m;page=2;lang=en")
    end

    test "{;...} variables are optional and an unknown name is ignored" do
      assert {:ok, %{}} = match("m{;lang,page}", "m")
      assert {:ok, %{"lang" => "en"}} = match("m{;lang,page}", "m;lang=en")
      assert {:ok, %{"lang" => "en"}} = match("m{;lang,page}", "m;x=1;lang=en")
      assert {:ok, %{"lang" => "en"}} = match("m{;lang,page}", "m;x=1;x=2;lang=en")
      assert match("m{;lang,page}", "m;lang=en;lang=fr") == :nomatch
    end

    test "{;x} and {;x=} give an empty value" do
      assert {:ok, %{"x" => ""}} = match("m{;x}", "m;x")
      assert {:ok, %{"x" => ""}} = match("m{;x}", "m;x=")
    end

    test "a param value does not hold a decoded '/'" do
      assert match("m{;x}", "m;x=1%2F2") == :nomatch
    end

    test "a fragment value crosses '/'" do
      assert {:ok, %{"p" => "a/b"}} = match("x{#p}", "x#a/b")
      assert {:ok, %{"p" => "a/b"}} = match("x{#p}", "x#a%2Fb")
    end
  end

  describe "the backtrack" do
    test "a literal between two variables takes the longest first value" do
      assert {:ok, %{"a" => "x.y", "b" => "z"}} = match("{a}.{b}", "x.y.z")
    end

    test "the walk goes back to each earlier position of the literal" do
      assert {:ok, %{"a" => "x", "b" => "y"}} = match("{a}.{b}", "x.y")
      assert {:ok, %{"a" => "x.y.z", "b" => "w"}} = match("{a}.{b}", "x.y.z.w")
    end

    test "a literal after a reserved value lets the value cross '/'" do
      assert {:ok, %{"p" => "a/b"}} = match("{+p}.md", "a/b.md")
    end
  end

  describe "adjacent expressions with no literal between them" do
    test "the value of the first expression stops before the prefix of a required expression" do
      matches = [
        {"file:///{+path}{.ext}", "file:///a/b.md", %{"path" => "a/b", "ext" => "md"}},
        {"file:///{+path}{.ext}", "file:///a/b.c.md", %{"path" => "a/b.c", "ext" => "md"}},
        {"file:///{name}{.ext}", "file:///b.md", %{"name" => "b", "ext" => "md"}},
        {"file:///{+path}{/x}", "file:///a/b", %{"path" => "a", "x" => "b"}},
        {"file:///{+path}{/x}", "file:///a/b/c", %{"path" => "a/b", "x" => "c"}},
        {"api{/a}{.fmt}", "api/x.json", %{"a" => "x", "fmt" => "json"}},
        {"x{#a}{/b}", "x#1/2", %{"a" => "1", "b" => "2"}},
        {"x{+a,b}{.e}", "x1,2.md", %{"a" => "1", "b" => "2", "e" => "md"}}
      ]

      for {template, uri, params} <- matches do
        assert {:ok, ^params} = match(template, uri), "#{template} against #{uri}"
      end
    end

    test "the prefix character of an optional expression joins the stop set" do
      matches = [
        {"file:///{+path}{?v}", "file:///a/b?v=1", %{"path" => "a/b", "v" => "1"}},
        {"file:///{name}{;v}", "file:///a;v=1", %{"name" => "a", "v" => "1"}},
        {"x/{a}{&b}", "x/1&b=2", %{"a" => "1", "b" => "2"}},
        {"x{+a}{;b}", "x1;b=2", %{"a" => "1", "b" => "2"}},
        {"x{;a}{&b}", "x;a=1&b=2", %{"a" => "1", "b" => "2"}}
      ]

      for {template, uri, params} <- matches do
        assert {:ok, ^params} = match(template, uri), "#{template} against #{uri}"
      end
    end

    test "the character of the optional expression must come as a percent triplet" do
      assert {:ok, %{"path" => "a?b", "v" => "1"}} =
               match("file:///{+path}{?v}", "file:///a%3Fb?v=1")

      assert {:ok, %{"name" => "a;b", "v" => "1"}} =
               match("file:///{name}{;v}", "file:///a%3Bb;v=1")
    end

    test "an absent optional expression after another expression matches" do
      assert {:ok, %{"path" => "a/b"}} = match("file:///{+path}{?v}", "file:///a/b")
      assert {:ok, %{"name" => "a"}} = match("file:///{name}{;v}", "file:///a")
      assert {:ok, %{"a" => "1"}} = match("x/{a}{&b}", "x/1")
    end

    test "the pairs that needed no change still match" do
      matches = [
        {"x/{a}{?q}", "x/1?q=2", %{"a" => "1", "q" => "2"}},
        {"x/{a}{/b}", "x/1/2", %{"a" => "1", "b" => "2"}},
        {"x/{a}{#f}", "x/1#f", %{"a" => "1", "f" => "f"}},
        {"x{.a}{.b}", "x.1.2", %{"a" => "1", "b" => "2"}},
        {"x{/a}{/b}", "x/1/2", %{"a" => "1", "b" => "2"}},
        {"x{#a}{#b}", "x#1#2", %{"a" => "1", "b" => "2"}},
        {"x{+a}{#f}", "x1#f", %{"a" => "1", "f" => "f"}},
        {"x{;a}{/b}", "x;a=1/2", %{"a" => "1", "b" => "2"}},
        {"x{?a}{#f}", "x?a=1#2", %{"a" => "1", "f" => "2"}}
      ]

      for {template, uri, params} <- matches do
        assert {:ok, ^params} = match(template, uri), "#{template} against #{uri}"
      end
    end

    test "a ';' pair of the next expression stays for that expression" do
      matches = [
        {"x{;a}{;b}", "x;a=1;b=2", %{"a" => "1", "b" => "2"}},
        {"x{;a}{;b}", "x;a=1", %{"a" => "1"}},
        {"x{;a}{;b}", "x;b=2", %{"b" => "2"}},
        {"x{;a}{;b}", "x", %{}},
        {"x{;a}{;b,c}", "x;c=3", %{"c" => "3"}},
        {"x{;a}{?b}", "x;b=2?b=3", %{"b" => "3"}},
        {"x{;a}{&b}", "x;b=2&b=3", %{"b" => "3"}}
      ]

      for {template, uri, params} <- matches do
        assert {:ok, ^params} = match(template, uri), "#{template} against #{uri}"
      end
    end

    test "a ';' pair with an empty name gives no match" do
      assert match("x{;a}", "x;;a=1") == :nomatch
      assert match("x{;a}", "x;") == :nomatch
      assert match("x{;a}", "x;a=1;") == :nomatch
      assert match("x{;a}", "x;a=1;;b=2") == :nomatch
    end

    test "each accepted pair of adjacent expressions matches its own expansion" do
      e1 = [
        {"", :simple},
        {"+", :reserved},
        {"#", :fragment},
        {".", :label},
        {"/", :path},
        {";", :param},
        {"?", :query},
        {"&", :cont}
      ]

      e2 = [
        {"#", :fragment},
        {".", :label},
        {"/", :path},
        {";", :param},
        {"?", :query},
        {"&", :cont}
      ]

      optional = [:param, :query, :cont]

      for {c1, op1} <- e1, {c2, op2} <- e2 do
        template = "x{#{c1}a}{#{c2}b}"
        combos = [{{"1", "2"}, %{"a" => "1", "b" => "2"}}]

        combos =
          if op1 in optional do
            [{{nil, "2"}, %{"b" => "2"}} | combos]
          else
            combos
          end

        combos =
          if op2 in optional do
            combos ++ [{{"1", nil}, %{"a" => "1"}}]
          else
            combos
          end

        case TemplateUri.compile(template) do
          {:error, message} ->
            assert message =~ "ambiguous adjacent expressions" or
                     message =~ "only {#...} may follow {?...} or {&...}",
                   "#{template}: #{message}"

          {:ok, compiled} ->
            for {{value_a, value_b}, expected} <- combos do
              uri = "x" <> expand(op1, "a", value_a) <> expand(op2, "b", value_b)

              assert {:ok, ^expected} = Matcher.run(compiled, uri),
                     "#{template} against #{uri}"
            end
        end
      end
    end

    defp expand(:simple, _name, value), do: value
    defp expand(:reserved, _name, value), do: value
    defp expand(:fragment, _name, value), do: "##{value}"
    defp expand(:label, _name, value), do: ".#{value}"
    defp expand(:path, _name, value), do: "/#{value}"
    defp expand(:param, _name, nil), do: ""
    defp expand(:param, name, value), do: ";#{name}=#{value}"
    defp expand(:query, _name, nil), do: ""
    defp expand(:query, name, value), do: "?#{name}=#{value}"
    defp expand(:cont, _name, nil), do: ""
    defp expand(:cont, name, value), do: "&#{name}=#{value}"
  end

  describe "the budget" do
    test "a uri that matches gives :nomatch with a small budget" do
      compiled = TemplateUri.compile!("{a}-{b}-{c}-{d}")

      assert {:ok, %{"a" => "1", "b" => "2", "c" => "3", "d" => "4"}} =
               Matcher.run(compiled, "1-2-3-4")

      assert Matcher.run(compiled, "1-2-3-4", 2) == :nomatch
    end
  end

  describe "the cost of a match" do
    test "a hostile uri of 16 KiB gives :nomatch within the default budget" do
      hostile = [
        {"{+a}.{b}", "x" <> String.duplicate(".", 16_382) <> "/"},
        {"file:///{+path}.md", "file:///" <> String.duplicate(".md", 5_458) <> "/"},
        {"{a}-{b}-{c}-{d}", "x" <> String.duplicate("-", 16_382) <> "/"}
      ]

      for {template, uri} <- hostile do
        assert byte_size(uri) <= 16_384
        compiled = TemplateUri.compile!(template)
        assert {result, units} = Matcher.cost(compiled, uri, Matcher.default_budget())
        assert result == :nomatch
        assert units <= Matcher.default_budget()
        assert Matcher.run(compiled, uri) == :nomatch
      end
    end

    test "a small budget spends its units and answers :nomatch" do
      compiled = TemplateUri.compile!("{a}-{b}-{c}-{d}")
      assert {:nomatch, units} = Matcher.cost(compiled, "1-2-3-4", 2)
      assert units <= 2
    end

    test "a match reports the units that it used" do
      compiled = TemplateUri.compile!("users/{id}")

      assert {{:ok, %{"id" => "42"}}, units} =
               Matcher.cost(compiled, "users/42", Matcher.default_budget())

      assert units > 0 and units <= Matcher.default_budget()
    end
  end

  describe "random strings" do
    test "the matcher never raises and answers :nomatch or {:ok, params}" do
      :rand.seed(:exsss, {6570, 10, 28})

      compiled_list =
        Enum.map(
          [
            "users/{id}",
            "file:///{+path}",
            "{a}.{b}",
            "r/{a,b}",
            "doc{#frag}",
            "img{.ext}",
            "api{/ver,id}",
            "m{;lang,page}",
            "s{?q,n}",
            "s?x=1{&q}",
            "{?a}{#f}",
            "plain/literal"
          ],
          &TemplateUri.compile!/1
        )

      pieces = [
        "a",
        "b",
        "/",
        "%20",
        "%2F",
        "%zz",
        "%4",
        "?",
        "#",
        "&",
        ";",
        "=",
        ".",
        "-",
        "é",
        <<0xFF>>
      ]

      for _ <- 1..300, compiled <- compiled_list do
        uri = random_uri(pieces)
        result = Matcher.run(compiled, uri)

        assert result == :nomatch or match?(%{}, elem(result, 1)),
               "unexpected answer #{inspect(result)} for #{inspect(uri)}"

        case result do
          {:ok, params} ->
            vars = MapSet.new(compiled.vars)
            assert MapSet.new(Map.keys(params)) |> MapSet.subset?(vars)

          :nomatch ->
            :ok
        end
      end
    end

    defp random_uri(pieces) do
      count = Enum.random(1..8)
      Enum.map_join(1..count, "", fn _ -> Enum.random(pieces) end)
    end
  end
end
