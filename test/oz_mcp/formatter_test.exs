defmodule OzMcp.FormatterTest do
  use ExUnit.Case, async: true

  @dsl_modules [
    OzMcp.Config.Server.DSL,
    OzMcp.Config.Tool.DSL,
    OzMcp.Config.Resource.DSL,
    OzMcp.Config.Template.DSL,
    OzMcp.Config.Prompt.DSL
  ]

  # The macros that take a `do` block only, for example `icon do ... end`.
  # The formatter keeps this form without parentheses, so the export
  # list needs no entry with the arity of these macros.
  #
  @do_block_macros [
    authorization: 1,
    capabilities: 1,
    icon: 1,
    list_result: 1,
    prompts: 1,
    resources: 1,
    server_info: 1,
    tasks: 1,
    templates: 1,
    tools: 1,
    annotations: 1,
    execution: 1,
    tool: 2,
    resource: 2,
    template: 2,
    prompt: 2
  ]

  test "the export list names only macros of the DSL" do
    names = @dsl_modules |> Enum.flat_map(&dsl_macros/1) |> MapSet.new(&elem(&1, 0))

    for {name, arity} <- exported_macros() do
      assert MapSet.member?(names, name),
             "the export list has #{name}/#{arity}, but no macro of the DSL has this name"
    end
  end

  test "each macro of the DSL is in the export list with its arity" do
    exported = MapSet.new(exported_macros())

    for {name, arity} <- Enum.flat_map(@dsl_modules, &dsl_macros/1),
        {name, arity} not in @do_block_macros do
      assert MapSet.member?(exported, {name, arity}),
             "the macro #{name}/#{arity} has no entry in the export list of .formatter.exs"
    end
  end

  test "the formatter keeps the exported calls without parentheses" do
    {formatter, _opts} = Mix.Tasks.Format.formatter_for_file("lib/sample.ex")

    code = """
    defmodule Sample do
      protocol_version "2025-11-25"
      instructions "Describe the server"
      name "sample"
      version "1.0.0"
      title "Sample"
      description "A sample server"
      website_url "https://example.com"
      experimental %{"example.com/preview" => %{}}
      logging %{}
      completions %{}
      paginate 20
      subscribe true
      tool SampleTool
      prompt SamplePrompt
      resource SampleResource
      template SampleTemplate
      verifier SampleVerifier
      authorization_servers ["https://auth.example.com"]
      scopes_supported ["reports:read"]
      challenge_scopes ["reports:read"]
      filter_by_scope true
      resource_name "Sample"
      resource_documentation "https://example.com/docs"
      meta "team", "engineering"
      extra "x-build", "2026.10"
      required_scopes ["reports:read"]
      input_schema %{type: "object"}
      output_schema %{type: "object"}
      task_support "optional"
      uri "file:///sample.md"
      uri_template "file:///sample/{path}"
      size 1
      audience ["user"]
      priority 0.5
      last_modified "2026-10-01T09:00:00Z"
      read_only_hint true
      destructive_hint false
      idempotent_hint true
      open_world_hint false
      src "https://example.com/icon.png"
      sizes ["48x48"]
      theme "light"
      mime_type "text/markdown"
      argument "language", required: true
      argument "focus"
    end
    """

    assert IO.iodata_to_binary(formatter.(code)) == code
  end

  defp exported_macros do
    {config, _binding} = Code.eval_file(".formatter.exs")
    config |> Keyword.fetch!(:export) |> Keyword.fetch!(:locals_without_parens)
  end

  defp dsl_macros(module) do
    {:docs_v1, _anno, _language, _format, _moduledoc, _metadata, docs} = Code.fetch_docs(module)

    for {{:macro, name, arity}, _anno, _signature, _doc, _meta} <- docs,
        not String.starts_with?(Atom.to_string(name), "__") do
      {name, arity}
    end
  end
end
