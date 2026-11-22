defmodule OzMcp.Utils.TemplateUri.ParserTest do
  use ExUnit.Case, async: true

  alias OzMcp.Utils.TemplateUri
  alias OzMcp.Utils.TemplateUri.Parser

  describe "parse/1 with a valid template" do
    test "returns the compiled data for one expression of each operator" do
      valid = [
        {"users/{id}",
         %{
           template: "users/{id}",
           prefix: "users/",
           vars: ["id"],
           shape: "users/{#}",
           parts: [{:lit, "users/"}, {:exp, :simple, [{"id", :plain}]}]
         }},
        {"r/{a,b}",
         %{
           template: "r/{a,b}",
           prefix: "r/",
           vars: ["a", "b"],
           shape: "r/{#,#}",
           parts: [{:lit, "r/"}, {:exp, :simple, [{"a", :plain}, {"b", :plain}]}]
         }},
        {"file:///{+path}",
         %{
           template: "file:///{+path}",
           prefix: "file:///",
           vars: ["path"],
           shape: "file:///{+#}",
           parts: [{:lit, "file:///"}, {:exp, :reserved, [{"path", :plain}]}]
         }},
        {"doc{#frag}",
         %{
           template: "doc{#frag}",
           prefix: "doc",
           vars: ["frag"],
           shape: "doc{##}",
           parts: [{:lit, "doc"}, {:exp, :fragment, [{"frag", :plain}]}]
         }},
        {"img{.ext}",
         %{
           template: "img{.ext}",
           prefix: "img",
           vars: ["ext"],
           shape: "img{.#}",
           parts: [{:lit, "img"}, {:exp, :label, [{"ext", :plain}]}]
         }},
        {"api{/ver,id}",
         %{
           template: "api{/ver,id}",
           prefix: "api",
           vars: ["ver", "id"],
           shape: "api{/#,#}",
           parts: [{:lit, "api"}, {:exp, :path, [{"ver", :plain}, {"id", :plain}]}]
         }},
        {"m{;lang,page}",
         %{
           template: "m{;lang,page}",
           prefix: "m",
           vars: ["lang", "page"],
           shape: "m{;lang,page}",
           parts: [{:lit, "m"}, {:exp, :param, [{"lang", :plain}, {"page", :plain}]}]
         }},
        {"s{?q,n}",
         %{
           template: "s{?q,n}",
           prefix: "s",
           vars: ["q", "n"],
           shape: "s{?n,q}",
           parts: [{:lit, "s"}, {:exp, :query, [{"q", :plain}, {"n", :plain}]}]
         }},
        {"s?x=1{&q}",
         %{
           template: "s?x=1{&q}",
           prefix: "s?x=1",
           vars: ["q"],
           shape: "s?x=1{&q}",
           parts: [{:lit, "s?x=1"}, {:exp, :cont, [{"q", :plain}]}]
         }},
        {"api{/ver,id}{?q}",
         %{
           template: "api{/ver,id}{?q}",
           prefix: "api",
           vars: ["ver", "id", "q"],
           shape: "api{/#,#}{?q}",
           parts: [
             {:lit, "api"},
             {:exp, :path, [{"ver", :plain}, {"id", :plain}]},
             {:exp, :query, [{"q", :plain}]}
           ]
         }}
      ]

      for {template, expected} <- valid do
        assert {:ok, compiled} = Parser.parse(template)
        assert compiled == expected
      end
    end

    test "accepts a template with no variable" do
      assert {:ok, compiled} = Parser.parse("plain/literal")

      assert compiled == %{
               template: "plain/literal",
               prefix: "plain/literal",
               vars: [],
               shape: "plain/literal",
               parts: [{:lit, "plain/literal"}]
             }
    end

    test "accepts an empty template" do
      assert {:ok, compiled} = Parser.parse("")
      assert compiled == %{template: "", prefix: "", vars: [], shape: "", parts: []}
    end

    test "accepts a UTF-8 literal and gives a byte prefix" do
      assert {:ok, compiled} = Parser.parse("héllo/{name}")
      assert compiled.prefix == "héllo/"
      assert compiled.vars == ["name"]
    end

    test "{.a} is the label operator with the variable a" do
      assert {:ok, compiled} = Parser.parse("{.a}")
      assert compiled.parts == [{:exp, :label, [{"a", :plain}]}]
      assert compiled.vars == ["a"]
    end

    test "accepts a fragment expression after a query expression" do
      assert {:ok, compiled} = Parser.parse("{?a}{#f}")

      assert compiled.parts == [
               {:exp, :query, [{"a", :plain}]},
               {:exp, :fragment, [{"f", :plain}]}
             ]

      assert compiled.prefix == ""
      assert compiled.shape == "{?a}{##}"
    end

    test "accepts an expression with a prefix operator after another expression" do
      valid = ["{a}{#b}", "{a}{.b}", "{a}{/b}", "{a}{;b}", "{a}{?b}", "{a}{&b}", "{+path}{/x}"]

      for template <- valid do
        assert {:ok, _compiled} = Parser.parse(template)
      end
    end

    test "accepts 16 expressions" do
      template = Enum.map_join(1..16, fn i -> "x{v#{i}}" end)
      assert {:ok, compiled} = Parser.parse(template)
      assert length(compiled.vars) == 16
    end
  end

  describe "parse/1 with a bad template" do
    test "refuses each case with a message that tells the position" do
      bad = [
        {"{a", "empty or unclosed expression at position 0"},
        {"a}", "unbalanced '}' at position 1"},
        {"{a}x}", "unbalanced '}' at position 4"},
        {"{{a}}", "unbalanced '{' at position 0"},
        {"{}", "empty or unclosed expression at position 0"},
        {"{a,}", "empty expression at position 0"},
        {"{=a}", "reserved operator '=' at position 0"},
        {"{,a}", "reserved operator ',' at position 0"},
        {"{!a}", "reserved operator '!' at position 0"},
        {"{@a}", "reserved operator '@' at position 0"},
        {"{|a}", "reserved operator '|' at position 0"},
        {"{a*}",
         "level 4 modifiers are not supported, use {+var} for a value with '/' at position 0"},
        {"{a:3}", "level 4 modifiers are not supported at position 0"},
        {"{a-b}", ~s(invalid variable name "a-b" at position 0)},
        {"{a b}", ~s(invalid variable name "a b" at position 0)},
        {"{a.}", ~s(invalid variable name "a." at position 0)},
        {"{a..b}", ~s(invalid variable name "a..b" at position 0)},
        {"{+.a}", ~s(invalid variable name ".a" at position 0)},
        {"{a}/{a}", ~s(duplicate variable name "a" at position 4)},
        {"{a}{b}", "ambiguous adjacent expressions at position 3"},
        {"{a}{+b}", "ambiguous adjacent expressions at position 3"},
        {"{?a}{&b}", "only {#...} may follow {?...} or {&...} at position 4"},
        {"{?a}x", "only {#...} may follow {?...} or {&...} at position 4"},
        {"{?a}{/b}", "only {#...} may follow {?...} or {&...} at position 4"},
        {"{&a}x", "only {#...} may follow {?...} or {&...} at position 4"},
        {"x{;p}{.f}", "ambiguous adjacent expressions at position 5"},
        {"{;a}{.b}", "ambiguous adjacent expressions at position 4"}
      ]

      for {template, message} <- bad do
        assert {:error, ^message} = Parser.parse(template)
      end
    end

    test "refuses a template that is not valid UTF-8" do
      assert {:error, "invalid UTF-8 at position 1"} = Parser.parse(<<97, 255, 98, 123>>)
      assert {:error, "invalid UTF-8 at position 0"} = Parser.parse(<<255, 97>>)
    end

    test "refuses more than 16 expressions" do
      template = Enum.map_join(1..17, fn i -> "{v#{i}}" end)

      position =
        1..16
        |> Enum.map(fn i -> byte_size("{v#{i}}") end)
        |> Enum.sum()

      message = "more than 16 expressions at position #{position}"
      assert {:error, ^message} = Parser.parse(template)
    end
  end

  describe "shape of the compiled data" do
    test "two templates that differ only in the variable names have the same shape" do
      {:ok, a} = Parser.parse("file:///{a}")
      {:ok, b} = Parser.parse("file:///{b}")
      assert a.shape == b.shape
    end

    test "a different operator gives a different shape" do
      {:ok, plain} = Parser.parse("a/{x}")
      {:ok, plus} = Parser.parse("a/{+x}")
      assert plain.shape != plus.shape
    end

    test "the query names matter, the order of the names does not" do
      {:ok, q} = Parser.parse("s{?q}")
      {:ok, n} = Parser.parse("s{?n}")
      {:ok, qn} = Parser.parse("s{?q,n}")
      {:ok, nq} = Parser.parse("s{?n,q}")

      assert q.shape != n.shape
      assert qn.shape == nq.shape
    end
  end

  describe "quoted round-trip of the compiled data" do
    test "survives Macro.escape/1 and Code.eval_quoted/1 unchanged" do
      templates = ["users/{id}", "file:///{+path}", "api{/ver,id}{?q}", "s{?q,n}", "doc{#f}"]

      for template <- templates do
        {:ok, compiled} = Parser.parse(template)
        quoted = Macro.escape(compiled)
        {evaluated, []} = Code.eval_quoted(quoted)
        assert evaluated == compiled
      end
    end
  end

  describe "TemplateUri.compile/1" do
    test "parses a valid template" do
      assert {:ok, %{template: "users/{id}", vars: ["id"]}} = TemplateUri.compile("users/{id}")
    end

    test "returns the error of the parser" do
      assert {:error, "empty or unclosed expression at position 0"} = TemplateUri.compile("{a")
    end
  end

  describe "TemplateUri.compile!/1" do
    test "returns the compiled data" do
      compiled = TemplateUri.compile!("users/{id}")
      assert compiled.template == "users/{id}"
      assert compiled.vars == ["id"]
      assert compiled.prefix == "users/"
    end

    test "raises ArgumentError for a bad template" do
      message = ~s(invalid URI template "{a": empty or unclosed expression at position 0)

      assert_raise ArgumentError, message, fn ->
        TemplateUri.compile!("{a")
      end
    end
  end
end
