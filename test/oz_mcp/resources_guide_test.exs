#
# The guide about the resources must give a row for each macro of the
# resource DSL and must name each callback of the resource behaviour.
#
defmodule OzMcp.ResourcesGuideTest do
  use ExUnit.Case, async: true

  @guide Path.join(File.cwd!(), "guides/entities/resources.md")

  # The macros of the resource DSL, with the text that the row of the
  # macro must name: the macro as the table of the guide writes it and
  # the wire field. The list mirrors the user-facing macros of
  # `OzMcp.Config.Resource.DSL`.
  #
  @macros [
    {:resource, 2, ~s(`resource "name"`), "`name`"},
    {:uri, 1, "`uri`", "`uri`"},
    {:title, 1, "`title`", "`title`"},
    {:description, 1, "`description`", "`description`"},
    {:mime_type, 1, "`mime_type`", "`mimeType`"},
    {:size, 1, "`size`", "`size`"},
    {:required_scopes, 1, "`required_scopes`", "none"},
    {:annotations, 1, "`annotations`", "`annotations`"},
    {:audience, 1, "`audience`", "`annotations.audience`"},
    {:priority, 1, "`priority`", "`annotations.priority`"},
    {:last_modified, 1, "`last_modified`", "`annotations.lastModified`"},
    {:icon, 1, "`icon`", "`icons`"},
    {:src, 1, "`src`", "`icons[].src`"},
    {:sizes, 1, "`sizes`", "`icons[].sizes`"},
    {:theme, 1, "`theme`", "`icons[].theme`"},
    {:meta, 2, "`meta key, value`", "`_meta.<key>`"}
  ]

  # The callbacks of the resource behaviour, with the code line that the
  # guide must show for the callback.
  #
  @callbacks [
    read: "def read(ctx, params)",
    complete: "complete/4",
    list: "list/0"
  ]

  setup do
    %{guide: File.read!(@guide)}
  end

  test "each macro of the resource DSL has a row with its wire field", %{guide: guide} do
    rows =
      guide
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "| `"))
      |> Enum.map(fn row ->
        cells = row |> String.split("|") |> Enum.map(&String.trim/1)

        # The row starts with a pipe: the first cell is the second part.
        #
        {Enum.at(cells, 1), row}
      end)

    # The macros of the DSL module, without the internal helpers.
    #
    internal =
      ~w(__before_compile__ __get_context__ __get_from_cache__ __put_in_cache__ __set_path__ __using__)

    dsl_macros =
      for {name, arity} <- OzMcp.Config.Resource.DSL.__info__(:macros),
          Atom.to_string(name) not in internal do
        {name, arity}
      end
      |> Enum.sort()

    for {name, arity, needle, wire_field} <- @macros do
      assert {name, arity} in dsl_macros,
             "the test does not expect the macro #{name}/#{arity} of the DSL"

      entry = Enum.find(rows, &(elem(&1, 0) == needle))

      assert entry, "the table of the guide has no row for #{needle}"
      assert elem(entry, 1) =~ wire_field, "the row of #{needle} does not mention #{wire_field}"
    end

    assert length(dsl_macros) == length(@macros),
           "the DSL has a macro that the test does not expect: #{inspect(dsl_macros)}"
  end

  test "each callback of the resource behaviour is in the guide", %{guide: guide} do
    callbacks = OzMcp.Config.Resource.behaviour_info(:callbacks)

    for {name, arity} <- callbacks do
      entry = Enum.find(@callbacks, &(elem(&1, 0) == name))

      assert entry, "the test has no entry for the callback #{name}/#{arity}"

      needle = entry |> elem(1)

      assert guide =~ needle, "the guide does not mention #{needle}"
    end
  end
end
