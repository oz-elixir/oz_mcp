defmodule OzMcp.EntityReadsTest do
  use ExUnit.Case, async: true

  # No reader of an entity or of a result reads both key forms: a
  # normalized entity is a struct, so its fields are the only reads. The
  # allow list holds the dual reads that are not on an entity: the
  # capabilities of the server config, the type of a JSON schema and an
  # option map of an elicitation schema.
  #
  @dual [
    ~r/Map\.get\([^()]*, :\w+\)\s*\|\|\s*Map\.get\([^()]*, "/,
    ~r/Map\.get\([^()]*, :\w+, Map\.get\([^()]*, "/
  ]

  @allowed [
    {"lib/oz_mcp/pipeline/helpers.ex",
     "Map.get(capabilities, :tasks) || Map.get(capabilities, \"tasks\")"},
    {"lib/oz_mcp/method/capabilities.ex",
     "do: Map.get(capabilities, :completions) || Map.get(capabilities, \"completions\"),"},
    {"lib/oz_mcp/config/dsl/rules.ex",
     "case Map.get(schema, :type, Map.get(schema, \"type\")) do"},
    {"lib/oz_mcp/structs/enum_options.ex",
     "value = Map.get(map, :const) || Map.get(map, \"const\")"},
    {"lib/oz_mcp/structs/enum_options.ex",
     "title = Map.get(map, :title) || Map.get(map, \"title\")"}
  ]

  test "no reader of an entity reads both key forms" do
    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          {line, number} <- path |> File.stream!() |> Enum.with_index(1),
          Enum.any?(@dual, &(line =~ &1)),
          {path, String.trim(line)} not in @allowed,
          do: "#{path}:#{number}"

    assert offenders == []
  end
end
