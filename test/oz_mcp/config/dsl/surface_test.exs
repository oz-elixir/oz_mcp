#
# Pins the public macros of the five DSL modules. A macro loses its
# place in the DSL if a change of the tables forgets it, so this test
# fails before any other test.
#
defmodule OzMcp.Config.DSL.SurfaceTest do
  use ExUnit.Case, async: true

  defp macros(module) do
    for {name, arity} <- module.__info__(:macros),
        not String.starts_with?(Atom.to_string(name), "__") do
      {name, arity}
    end
    |> Enum.sort()
  end

  test "the prompt DSL keeps its macros" do
    assert macros(OzMcp.Config.Prompt.DSL) == [
             argument: 1,
             argument: 2,
             description: 1,
             icon: 1,
             meta: 2,
             mime_type: 1,
             prompt: 2,
             required_scopes: 1,
             sizes: 1,
             src: 1,
             theme: 1,
             title: 1
           ]
  end

  test "the tool DSL keeps its macros" do
    assert macros(OzMcp.Config.Tool.DSL) == [
             annotations: 1,
             description: 1,
             destructive_hint: 1,
             execution: 1,
             icon: 1,
             idempotent_hint: 1,
             immediate_response: 1,
             input_schema: 1,
             meta: 2,
             mime_type: 1,
             open_world_hint: 1,
             output_schema: 1,
             poll_interval: 1,
             read_only_hint: 1,
             required_scopes: 1,
             sizes: 1,
             src: 1,
             task_support: 1,
             theme: 1,
             title: 1,
             tool: 2
           ]
  end

  test "the resource DSL keeps its macros" do
    assert macros(OzMcp.Config.Resource.DSL) == [
             annotations: 1,
             audience: 1,
             description: 1,
             icon: 1,
             last_modified: 1,
             meta: 2,
             mime_type: 1,
             priority: 1,
             required_scopes: 1,
             resource: 2,
             size: 1,
             sizes: 1,
             src: 1,
             theme: 1,
             title: 1,
             uri: 1
           ]
  end

  test "the template DSL keeps its macros" do
    assert macros(OzMcp.Config.Template.DSL) == [
             annotations: 1,
             audience: 1,
             description: 1,
             icon: 1,
             last_modified: 1,
             meta: 2,
             mime_type: 1,
             priority: 1,
             required_scopes: 1,
             sizes: 1,
             src: 1,
             template: 2,
             theme: 1,
             title: 1,
             uri_template: 1
           ]
  end

  test "the server DSL keeps its macros" do
    assert macros(OzMcp.Config.Server.DSL) == [
             audience_check: 1,
             authorization: 1,
             authorization_servers: 1,
             cancel: 1,
             capabilities: 1,
             challenge_scopes: 1,
             completions: 1,
             description: 1,
             experimental: 1,
             extra: 2,
             filter_by_scope: 1,
             icon: 1,
             instructions: 1,
             list: 1,
             list_result: 1,
             logging: 1,
             meta: 2,
             mime_type: 1,
             name: 1,
             paginate: 1,
             prompt: 1,
             prompts: 1,
             protocol_version: 1,
             requests: 1,
             resource: 1,
             resource_documentation: 1,
             resource_name: 1,
             resources: 1,
             scopes_supported: 1,
             server_info: 1,
             sizes: 1,
             src: 1,
             subscribe: 1,
             tasks: 1,
             template: 1,
             templates: 1,
             theme: 1,
             title: 1,
             tool: 1,
             tools: 1,
             verifier: 1,
             version: 1,
             website_url: 1
           ]
  end
end
