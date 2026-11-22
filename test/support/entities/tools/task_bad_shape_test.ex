# Test support tool module for the result shape of a task tool.
#

#
# Tool whose result shape the argument "shape" selects. It serves the
# checks of the result shape on the task path and on the direct path:
#
#   * "empty_map": `{:ok, %{}}` — a map with no `content`;
#   * "text": `{:ok, "text"}` — not a map at all;
#   * "string_content": a plain map with the string key `"content"`;
#   * "bad_meta": a plain map whose `_meta` holds a key of a bad format;
#   * "reserved_meta": a plain map whose `_meta` holds a reserved prefix;
#   * "bad_utf8": a plain map whose text content is not valid UTF-8;
#   * "framework_meta": a plain map whose `_meta` holds the key that the
#     framework writes;
#   * "bad_content": a plain map whose `content` is not a list;
#   * "no_type": a plain map whose content block has no `type`;
#   * "bad_annotations": a plain map whose content block holds an
#     `annotations` of the wrong shape;
#   * "not_json": a plain map that holds a value that JSON cannot encode;
#   * "duplicate_key": a plain map whose `structuredContent` holds the same
#     key as an atom and as a string;
#   * "empty_text": a struct result with a text content that is empty;
#   * "reserved_error": `{:error, ...}` with the reserved code -32800;
#   * "bad_is_error": a plain map whose `isError` is not a boolean;
#   * "bad_structured": a plain map whose `structuredContent` is not an
#     object;
#   * any other value: a built `%CallToolResult{}` with one text content.
#
defmodule Support.Entities.Tools.TaskBadShapeTest do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.{CallToolResult, TextContent, Tool, ToolExecution}

  def list do
    list = [
      %Tool{}
      |> Tool.name("task_bad_shape")
      |> Tool.description("Returns a result of the shape the argument selects")
      |> Tool.execution(%ToolExecution{} |> ToolExecution.task_support(:optional))
    ]

    list
  end

  def call(_ctx, %{"arguments" => %{"shape" => "empty_map"}}) do
    {:ok, %{}}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "text"}}) do
    {:ok, "text"}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "string_content"}}) do
    {:ok, %{"content" => [%{"type" => "text", "text" => "ok"}]}}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "bad_content"}}) do
    {:ok, %{"content" => "not a list"}}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "bad_is_error"}}) do
    {:ok, %{"content" => [%{"type" => "text", "text" => "ok"}], "isError" => "maybe"}}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "bad_structured"}}) do
    {:ok, %{"content" => [], "structuredContent" => [1, 2]}}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "bad_meta"}}) do
    {:ok, %{"content" => [], "_meta" => %{"my key" => 1}}}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "reserved_meta"}}) do
    {:ok, %{"content" => [], "_meta" => %{"io.modelcontextprotocol/x" => 1}}}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "bad_utf8"}}) do
    {:ok, %{"content" => [%{"type" => "text", "text" => <<0xFF>>}]}}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "no_type"}}) do
    {:ok, %{"content" => [%{"text" => "no type"}]}}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "bad_annotations"}}) do
    {:ok,
     %{
       "content" => [
         %{"type" => "text", "text" => "x", "annotations" => %{"priority" => "high"}}
       ]
     }}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "not_json"}}) do
    {:ok, %{"content" => [], "secret" => self()}}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "duplicate_key"}}) do
    {:ok, %{"content" => [], "structuredContent" => %{"a" => 1, :a => 2}}}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "empty_text"}}) do
    {:ok, %CallToolResult{content: [%TextContent{text: ""}]}}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "reserved_error"}}) do
    {:error, %{code: -32800, message: "gone"}}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "framework_meta"}}) do
    {:ok,
     %{
       "content" => [],
       "_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => "t1"}}
     }}
  end

  def call(_ctx, _params) do
    result =
      %CallToolResult{}
      |> CallToolResult.content([
        %TextContent{}
        |> TextContent.text("ok")
      ])
      |> CallToolResult.build()

    {:ok, result}
  end
end
