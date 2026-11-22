defmodule OzMcp.Structs.SchemaFieldsTest do
  use ExUnit.Case, async: true

  @path "test/fixtures/mcp/2025-11-25/schema.json"
  @external_resource @path
  @document @path |> File.read!() |> JSON.decode!()

  @defs_key if Map.has_key?(@document, "$defs"), do: "$defs", else: "definitions"

  # Fields that the schema has and the struct does not.
  #
  @allowed_gaps %{}

  # `EnumSchema` and `MultiSelectEnumSchema` are unions of variant definitions
  # (`anyOf`), so they have no properties to compare.
  #
  @structs [
    {OzMcp.Structs.Annotations, "Annotations"},
    {OzMcp.Structs.AudioContent, "AudioContent"},
    {OzMcp.Structs.BlobResourceContents, "BlobResourceContents"},
    {OzMcp.Structs.BooleanSchema, "BooleanSchema"},
    {OzMcp.Structs.CallToolResult, "CallToolResult"},
    {OzMcp.Structs.CompleteResult, "CompleteResult"},
    {OzMcp.Structs.CreateMessageRequestParams, "CreateMessageRequestParams"},
    {OzMcp.Structs.CreateTaskResult, "CreateTaskResult"},
    {OzMcp.Structs.ElicitRequestFormParams, "ElicitRequestFormParams"},
    {OzMcp.Structs.ElicitRequestURLParams, "ElicitRequestURLParams"},
    {OzMcp.Structs.EmbeddedResource, "EmbeddedResource"},
    {OzMcp.Structs.GetPromptResult, "GetPromptResult"},
    {OzMcp.Structs.Icon, "Icon"},
    {OzMcp.Structs.ImageContent, "ImageContent"},
    {OzMcp.Structs.Implementation, "Implementation"},
    {OzMcp.Structs.InitializeResult, "InitializeResult"},
    {OzMcp.Structs.ModelPreferences, "ModelPreferences"},
    {OzMcp.Structs.NotificationParams, "NotificationParams"},
    {OzMcp.Structs.NumberSchema, "NumberSchema"},
    {OzMcp.Structs.Prompt, "Prompt"},
    {OzMcp.Structs.PromptArgument, "PromptArgument"},
    {OzMcp.Structs.PromptMessage, "PromptMessage"},
    {OzMcp.Structs.ReadResourceResult, "ReadResourceResult"},
    {OzMcp.Structs.RelatedTaskMetadata, "RelatedTaskMetadata"},
    {OzMcp.Structs.Resource, "Resource"},
    {OzMcp.Structs.ResourceLink, "ResourceLink"},
    {OzMcp.Structs.ResourceTemplate, "ResourceTemplate"},
    {OzMcp.Structs.Root, "Root"},
    {OzMcp.Structs.SamplingMessage, "SamplingMessage"},
    {OzMcp.Structs.ServerCapabilities, "ServerCapabilities"},
    {OzMcp.Structs.StringSchema, "StringSchema"},
    {OzMcp.Structs.Task, "Task"},
    {OzMcp.Structs.TaskMetadata, "TaskMetadata"},
    {OzMcp.Structs.TextContent, "TextContent"},
    {OzMcp.Structs.TextResourceContents, "TextResourceContents"},
    {OzMcp.Structs.Tool, "Tool"},
    {OzMcp.Structs.ToolAnnotations, "ToolAnnotations"},
    {OzMcp.Structs.ToolChoice, "ToolChoice"},
    {OzMcp.Structs.ToolExecution, "ToolExecution"},
    {OzMcp.Structs.ToolResultContent, "ToolResultContent"},
    {OzMcp.Structs.ToolUseContent, "ToolUseContent"}
  ]

  for {module, name} <- @structs do
    test "#{name} has the fields of the schema" do
      properties = @document[@defs_key][unquote(name)]["properties"] || %{}
      schema_keys = properties |> Map.keys() |> MapSet.new()
      struct_keys = unquote(module).__fields__() |> MapSet.new(&Atom.to_string/1)
      gaps = Map.get(@allowed_gaps, unquote(name), [])

      assert schema_keys |> MapSet.difference(struct_keys) |> Enum.sort() == Enum.sort(gaps)

      assert struct_keys |> MapSet.difference(schema_keys) |> MapSet.size() == 0
    end
  end
end
