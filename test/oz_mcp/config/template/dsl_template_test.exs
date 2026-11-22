# Tests for the `template/2` macro of the template DSL.
# See: lib/oz_mcp/config/template/dsl.ex
#

#
# A template module and a server with unique template strings, used to
# check that the DSL path never touches the run-time cache.
#
defmodule TemplateDslCacheProbeTest do
  use OzMcp.Config.Template, warn?: false

  template "Cache probe" do
    uri_template "probe://dsl-cache/{unique_key}"
    title "Cache probe"
    description "Cache probe template"
  end

  def read(_ctx, _params, _uri_template, _uri_params), do: {:ok, %{}}
end

defmodule ServerTemplateDslCacheProbeTest do
  use OzMcp.Config.Server

  server_info do
    name "dsl-cache-probe"
    version "1.0.0"
  end

  templates do
    template TemplateDslCacheProbeTest
  end

  capabilities do
    resources do
    end
  end
end

defmodule OzMcp.Config.Template.DSLTemplateTest do
  use ExUnit.Case, async: true
  import Support.Factories.Template

  describe "template/2" do
    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when template name is not a string" do
      module("Template") do
        template(123)
      end
      |> assert_compile_raise(ArgumentError, "name must be a string, got: 123")
    end

    test "raises when template name is an empty string" do
      module("Template") do
        template("")
      end
      |> assert_compile_raise(ArgumentError, "'name' cannot be an empty string")
    end

    test "raises when uri_template is not present" do
      module("Template") do
        template("doc", uri_template: :_none_)
      end
      |> assert_compile_raise(RuntimeError, "template 'uri_template' is required")
    end

    test "raises when two templates have the same uri_template" do
      module("Template") do
        template("first", uri_template: "file:///{path}")
        template("second", uri_template: "file:///{path}")
      end
      |> assert_compile_raise(
        ArgumentError,
        "duplicate template uri_template: \"file:///{path}\" is declared two times"
      )
    end

    test "raises when two templates differ only in their variable names" do
      module("Template") do
        template("first", uri_template: "file:///{a}")
        template("second", uri_template: "file:///{b}")
      end
      |> assert_compile_raise(
        ArgumentError,
        "duplicate template uri_template shape: \"file:///{b}\" has the same shape as \"file:///{a}\""
      )
    end

    test "raises when two query templates have the same names in a different order" do
      module("Template") do
        template("first", uri_template: "s{?q,n}")
        template("second", uri_template: "s{?n,q}")
      end
      |> assert_compile_raise(
        ArgumentError,
        "duplicate template uri_template shape: \"s{?n,q}\" has the same shape as \"s{?q,n}\""
      )
    end

    test "accepts templates whose uri_templates have different shapes" do
      module("Template") do
        template("plain", uri_template: "file:///{a}")
        template("reserved", uri_template: "file:///{+a}")
        template("nested", uri_template: "a/{x}/b")
        template("query-q", uri_template: "s{?q}")
        template("query-n", uri_template: "s{?n}")
      end
      |> compile()
    end

    test "accepts two templates with the same name and different uri_templates" do
      mod =
        module("Template") do
          template("doc", uri_template: "https://a.example/{path}", title: "First")
          template("doc", uri_template: "https://b.example/{path}", title: "Second")
        end
        |> compile()

      assert Enum.map(mod.list(), & &1.uriTemplate) == [
               "https://a.example/{path}",
               "https://b.example/{path}"
             ]
    end

    # -----------------------------------------------------------------------
    # Warnings
    # -----------------------------------------------------------------------

    test "warn?: true emits warning when title is missing in template" do
      module("Template", _warn_: true) do
        template("doc", description: "A doc")
      end
      |> assert_compile_warning("The template doc does not have a title configuration")
    end

    test "warn?: true emits warning when description is missing in template" do
      module("Template", _warn_: true) do
        template("doc", title: "Doc")
      end
      |> assert_compile_warning("The template doc does not have a description configuration")
    end

    test "warn?: true emits both warnings when title and description are missing in template" do
      module("Template", _warn_: true) do
        template("doc")
      end
      |> assert_compile_warning("The template doc does not have a title configuration")

      module("Template", _warn_: true) do
        template("doc")
      end
      |> assert_compile_warning("The template doc does not have a description configuration")
    end

    test "warn?: false suppresses template warnings when title and description are missing" do
      module("Template") do
        template("doc")
      end
      |> refute_compile_warning([
        "does not have a title configuration",
        "does not have a description configuration"
      ])
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when template block is nested inside another template block" do
      module("Template") do
        template("outer") do
          template("inner")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'template' here")
    end

    test "raises when template block is used inside icon block" do
      module("Template") do
        template("doc") do
          icon do
            template("inner")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'template' here")
    end

    test "raises when template block is used inside annotations block" do
      module("Template") do
        template("doc") do
          annotations(audience: ["user"]) do
            template("inner")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'template' here")
    end

    # -----------------------------------------------------------------------
    # Compiled matchers
    # -----------------------------------------------------------------------

    test "the matcher matches {+var} across '/' and decodes" do
      mod =
        module("Template") do
          template("doc", uri_template: "file:///{+path}")
        end
        |> compile()

      {template, params} = find_template(mod, "file:///a/b")
      assert template.uriTemplate == "file:///{+path}"
      assert params == %{"path" => "a/b"}

      {template, params} = find_template(mod, "file:///a%20b")
      assert template.uriTemplate == "file:///{+path}"
      assert params == %{"path" => "a b"}
    end

    test "the matcher does not let a simple variable cross '/' '?' '#' or a decoded '/'" do
      mod =
        module("Template") do
          template("doc", uri_template: "users/{id}")
        end
        |> compile()

      assert find_template(mod, "users/1/delete") == nil
      assert find_template(mod, "users/1%2Fdelete") == nil
      assert find_template(mod, "users/1?x") == nil
      assert find_template(mod, "users/1#x") == nil
      assert find_template(mod, "users/") == nil

      {template, params} = find_template(mod, "users/42")
      assert template.uriTemplate == "users/{id}"
      assert params == %{"id" => "42"}
    end

    test "the matcher walks the templates in the declared order" do
      mod =
        module("Template") do
          template("first", uri_template: "file:///docs/{name}")
          template("second", uri_template: "file:///{+path}")
        end
        |> compile()

      {template, params} = find_template(mod, "file:///docs/x")
      assert template.uriTemplate == "file:///docs/{name}"
      assert params == %{"name" => "x"}

      {template, params} = find_template(mod, "file:///other/y/z")
      assert template.uriTemplate == "file:///{+path}"
      assert params == %{"path" => "other/y/z"}

      {template, params} = find_template(mod, "file:///docs/x/y")
      assert template.uriTemplate == "file:///{+path}"
      assert params == %{"path" => "docs/x/y"}
    end

    test "__catalog__/0 holds one compiled matcher per template, in the declared order" do
      mod =
        module("Template") do
          template("first", uri_template: "file:///docs/{name}")
          template("second", uri_template: "file:///{+path}")
        end
        |> compile()

      matchers = Enum.map(mod.__catalog__(), & &1.matcher)
      assert length(matchers) == 2
      assert Enum.map(matchers, & &1.template) == ["file:///docs/{name}", "file:///{+path}"]
      assert Enum.all?(matchers, &is_map/1)
      assert [first, second] = matchers
      assert first.prefix == "file:///docs/"
      assert second.prefix == "file:///"
    end

    test "__catalog__/0 holds the uri_template and the shape of each template, in the declared order" do
      mod =
        module("Template") do
          template("first", uri_template: "file:///{a}")
          template("second", uri_template: "s{?q,n}")
        end
        |> compile()

      assert Enum.map(mod.__catalog__(), &{&1.key, &1.matcher.shape}) == [
               {"file:///{a}", "file:///{#}"},
               {"s{?q,n}", "s{?n,q}"}
             ]
    end

    test "a DSL server never stores its templates in the run-time cache" do
      server = ServerTemplateDslCacheProbeTest
      catalog = OzMcp.Catalog.fetch(server)
      template_string = "probe://dsl-cache/{unique_key}"

      assert OzMcp.Catalog.find_template(catalog, "probe://dsl-cache/x") != nil

      for _ <- 1..1_000 do
        OzMcp.Catalog.find_template(catalog, "probe://dsl-cache/x")
      end

      assert :persistent_term.get({OzMcp.Utils.TemplateUri, template_string}, :none) == :none
    end
  end

  defp find_template(mod, uri) do
    catalog = %OzMcp.Catalog{templates: Enum.map(mod.__catalog__(), &{mod, &1})}

    case OzMcp.Catalog.find_template(catalog, uri) do
      {_module, template, params} -> {template, params}
      nil -> nil
    end
  end
end
