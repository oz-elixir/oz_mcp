defmodule OzMcp.Handler.ResultTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias OzMcp.Context
  alias OzMcp.Handler.{Invoke, Result}

  alias OzMcp.Structs.{
    Annotations,
    CallToolResult,
    CompleteResult,
    Completion,
    EmbeddedResource,
    GetPromptResult,
    Icon,
    ImageContent,
    PromptMessage,
    ReadResourceResult,
    ResourceLink,
    TextContent,
    TextResourceContents
  }

  @inline_server OzMcp.TestServerForDsl.ToolsOnly

  describe "tools/call" do
    test "accepts a valid map, with string keys and with atom keys" do
      assert {:ok, _} =
               Result.normalize("tools/call", %{
                 "content" => [%{"type" => "text", "text" => "x"}]
               })

      assert {:ok, _} =
               Result.normalize("tools/call", %{
                 content: [%{type: :text, text: "x"}],
                 isError: false
               })

      assert {:ok, _} =
               Result.normalize("tools/call", %{content: [], structuredContent: %{"a" => 1}})
    end

    test "refuses a content that is not a list, or a block with no type" do
      assert {:error, reason} = Result.normalize("tools/call", %{content: "not a list"})
      assert reason =~ "content"

      assert {:error, reason} =
               Result.normalize("tools/call", %{content: [%{"text" => "x"}]})

      assert reason =~ "type"

      assert {:error, _} = Result.normalize("tools/call", %{content: [%{type: nil}]})
      assert {:error, _} = Result.normalize("tools/call", %{content: ["text"]})
    end

    test "refuses isError and structuredContent of a bad type" do
      assert {:error, _} = Result.normalize("tools/call", %{content: [], isError: "maybe"})
      assert {:error, _} = Result.normalize("tools/call", %{content: [], isError: nil})

      assert {:error, reason} = Result.normalize("tools/call", %{content: [], _meta: nil})
      assert reason =~ "_meta"

      assert {:error, _} =
               Result.normalize("tools/call", %{content: [], structuredContent: [1]})
    end

    test "a map with no content gives the error of the missing member" do
      assert Result.normalize("tools/call", %{}) == {:error, "content is missing"}
    end

    test "keeps an unknown member" do
      assert {:ok, built} = Result.normalize("tools/call", %{"durationMs" => 12, content: []})
      assert built["durationMs"] == 12
      assert built.content == []
    end

    test "a map key extras is an unknown member, not the field" do
      assert {:ok, built} = Result.normalize("tools/call", %{content: [], extras: %{"a" => 1}})
      assert built[:extras] == %{"a" => 1}
    end

    test "accepts a custom _meta" do
      assert {:ok, built} =
               Result.normalize("tools/call", %{
                 "content" => [],
                 "_meta" => %{"com.example/revision" => "2"}
               })

      assert built._meta == %{"com.example/revision" => "2"}
    end

    test "refuses a bad _meta" do
      assert {:error, reason} =
               Result.normalize("tools/call", %{content: [], _meta: %{"my key" => 1}})

      assert reason =~ "my key"
    end

    test "a member under both key forms: the string key wins" do
      assert {:ok, built} =
               Result.normalize("tools/call", %{
                 "content" => [%{"type" => "text", "text" => "x"}],
                 content: []
               })

      assert JSON.encode!(built) ==
               JSON.encode!(%{content: [%{"type" => "text", "text" => "x"}]})
    end
  end

  describe "resources/read" do
    test "needs a list of objects with a uri" do
      assert {:ok, _} =
               Result.normalize("resources/read", %{contents: [%{uri: "file:///a", text: "x"}]})

      assert {:error, _} = Result.normalize("resources/read", %{contents: [%{text: "x"}]})
      assert {:error, _} = Result.normalize("resources/read", %{contents: [%{uri: ""}]})
      assert {:error, _} = Result.normalize("resources/read", %{contents: %{}})
      assert Result.normalize("resources/read", %{}) == {:error, "contents is missing"}
    end
  end

  describe "prompts/get" do
    test "needs a list of objects" do
      assert {:ok, _} = Result.normalize("prompts/get", %{messages: []})

      assert {:ok, _} =
               Result.normalize("prompts/get", %{
                 "messages" => [
                   %{"role" => "user", "content" => %{"type" => "text", "text" => "x"}}
                 ]
               })

      assert {:error, _} = Result.normalize("prompts/get", %{messages: ["hello"]})
      assert Result.normalize("prompts/get", %{}) == {:error, "messages is missing"}
    end
  end

  describe "completion/complete" do
    test "accepts at most 100 strings" do
      values = Enum.map(1..100, &Integer.to_string/1)

      assert {:ok, _} = Result.normalize("completion/complete", %{completion: %{values: values}})

      assert {:error, reason} =
               Result.normalize("completion/complete", %{completion: %{values: ["a" | values]}})

      assert reason =~ "at most 100"

      assert {:ok, _} =
               Result.normalize("completion/complete", %{
                 "completion" => %{"values" => [], "total" => 3}
               })
    end

    test "refuses a completion that is not an object with a list of strings" do
      assert Result.normalize("completion/complete", %{}) == {:error, "completion is missing"}

      assert {:error, _} = Result.normalize("completion/complete", %{completion: []})
      assert {:error, _} = Result.normalize("completion/complete", %{completion: %{}})

      assert {:error, _} =
               Result.normalize("completion/complete", %{completion: %{values: [1]}})

      assert {:error, _} =
               Result.normalize("completion/complete", %{completion: %{values: "a"}})
    end
  end

  test "has a rule for each method of methods/0" do
    for method <- Result.methods() do
      assert {:error, _} = Result.normalize(method, %{})
    end
  end

  # A map result and the equivalent struct result with the same bad
  # member give the same error.
  #
  describe "the same bad member gives the same error for a map and a struct" do
    test "tools/call: a text block with no text or with a text that is not a string" do
      for block <- [%{type: "text"}, %{type: "text", text: 1}] do
        map_error = error("tools/call", %{content: [block]})

        struct_error =
          error("tools/call", %{content: [struct(TextContent, Map.delete(block, :type))]})

        assert map_error == struct_error
      end
    end

    test "tools/call: an image block with no data" do
      map_error = error("tools/call", %{content: [%{type: "image", mimeType: "image/png"}]})

      struct_error =
        error("tools/call", %{content: [struct(ImageContent, mimeType: "image/png")]})

      assert map_error == struct_error
    end

    test "tools/call: a block with an unknown type or an unknown key still passes" do
      assert {:ok, built} =
               Result.normalize("tools/call", %{
                 content: [%{type: "com.example/widget", text: 1, _meta: %{"a b" => 1}}]
               })

      assert built.content == [%{type: "com.example/widget", text: 1, _meta: %{"a b" => 1}}]

      assert {:ok, built} =
               Result.normalize("tools/call", %{content: [%{type: "text", text: "x", vendor: 1}]})

      assert built.content == [%{type: "text", text: "x", vendor: 1}]
    end

    test "prompts/get: a message with a bad role, no content, or a block with no type" do
      for messages <- [
            [%{role: "robot", content: %{type: "text", text: "x"}}],
            [%{role: "user"}],
            [%{role: "user", content: %{text: "x"}}]
          ] do
        map_error = error("prompts/get", %{messages: messages})

        struct_error =
          error("prompts/get", %{
            messages: [
              %PromptMessage{
                role: Map.get(hd(messages), :role, :user),
                content: Map.get(hd(messages), :content)
              }
            ]
          })

        assert map_error == struct_error
      end
    end

    test "resources/read: a contents item with no text and no blob" do
      #
      # A map with no text and no blob names the item. The equivalent
      # struct (a text content with no text) fails in its build too.
      #
      map_error = error("resources/read", %{contents: [%{uri: "file:///a"}]})
      assert map_error =~ "'text' or a 'blob'"

      struct_error =
        error("resources/read", %{contents: [struct(TextResourceContents, uri: "file:///a")]})

      assert struct_error =~ "The 'text' field"

      for item <- [%{text: "x"}, %{uri: "", text: "x"}] do
        map_error = error("resources/read", %{contents: [item]})

        struct_error =
          error("resources/read", %{contents: [struct(TextResourceContents, item)]})

        assert map_error == struct_error
      end
    end

    test "completion/complete: a completion with a bad total or hasMore" do
      for completion <- [%{values: ["a"], total: "x"}, %{values: ["a"], hasMore: "yes"}] do
        map_error = error("completion/complete", %{completion: completion})

        struct_error =
          error("completion/complete", %{completion: struct(Completion, completion)})

        assert map_error == struct_error
      end
    end
  end

  describe "the three forms give the same JSON" do
    property "tools/call" do
      check all text <- StreamData.string(:alphanumeric, min_length: 1) do
        struct =
          %CallToolResult{}
          |> CallToolResult.content([%TextContent{} |> TextContent.text(text)])

        # The block itself in three forms: a struct, an atom-key map and
        # a string-key map.
        #
        atom_map = %{content: [%{type: "text", text: text}]}
        string_map = %{"content" => [%{"type" => "text", "text" => text}]}
        struct_block_map = %{content: [%TextContent{} |> TextContent.text(text)]}

        expected = json(CallToolResult.build(struct))

        assert json_map("tools/call", atom_map) == expected
        assert json_map("tools/call", string_map) == expected
        assert json_map("tools/call", struct_block_map) == expected
      end
    end

    property "tools/call with a resource link block" do
      check all name <- StreamData.string(:alphanumeric, min_length: 1),
                priority <- StreamData.float(min: 0.0, max: 1.0) do
        uri = "file:///" <> name
        src = "https://x/" <> name <> ".png"

        struct =
          %CallToolResult{}
          |> CallToolResult.content([
            %ResourceLink{}
            |> ResourceLink.uri(uri)
            |> ResourceLink.name(name)
            |> ResourceLink.annotations(%Annotations{} |> Annotations.priority(priority))
            |> ResourceLink.icons([%Icon{} |> Icon.src(src)])
          ])

        atom_map = %{
          content: [
            %{
              type: "resource_link",
              uri: uri,
              name: name,
              annotations: %{priority: priority},
              icons: [%{src: src}]
            }
          ]
        }

        string_map = %{
          "content" => [
            %{
              "type" => "resource_link",
              "uri" => uri,
              "name" => name,
              "annotations" => %{"priority" => priority},
              "icons" => [%{"src" => src}]
            }
          ]
        }

        expected = json(CallToolResult.build(struct))

        assert json_map("tools/call", atom_map) == expected
        assert json_map("tools/call", string_map) == expected
      end
    end

    property "resources/read" do
      check all text <- StreamData.string(:alphanumeric, min_length: 1) do
        uri = "file:///" <> text

        struct =
          %ReadResourceResult{}
          |> ReadResourceResult.contents([
            %TextResourceContents{}
            |> TextResourceContents.uri(uri)
            |> TextResourceContents.text(text)
          ])

        atom_map = %{contents: [%{uri: uri, text: text}]}
        string_map = %{"contents" => [%{"uri" => uri, "text" => text}]}

        struct_item_map = %{
          contents: [
            %TextResourceContents{}
            |> TextResourceContents.uri(uri)
            |> TextResourceContents.text(text)
          ]
        }

        expected = json(ReadResourceResult.build(struct))

        assert json_map("resources/read", atom_map) == expected
        assert json_map("resources/read", string_map) == expected
        assert json_map("resources/read", struct_item_map) == expected
      end
    end

    property "prompts/get" do
      check all text <- StreamData.string(:alphanumeric, min_length: 1) do
        struct =
          %GetPromptResult{}
          |> GetPromptResult.messages([
            %PromptMessage{role: :user, content: %TextContent{} |> TextContent.text(text)}
          ])

        atom_map = %{messages: [%{role: "user", content: %{type: "text", text: text}}]}

        string_map = %{
          "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => text}}]
        }

        struct_message_map = %{
          messages: [
            %PromptMessage{role: :user, content: %TextContent{} |> TextContent.text(text)}
          ]
        }

        expected = json(GetPromptResult.build(struct))

        assert json_map("prompts/get", atom_map) == expected
        assert json_map("prompts/get", string_map) == expected
        assert json_map("prompts/get", struct_message_map) == expected
      end
    end

    property "completion/complete" do
      check all text <- StreamData.string(:alphanumeric, min_length: 1) do
        struct =
          %CompleteResult{}
          |> CompleteResult.completion(%Completion{} |> Completion.values([text]))

        atom_map = %{completion: %{values: [text]}}
        string_map = %{"completion" => %{"values" => [text]}}
        struct_completion_map = %{completion: %Completion{} |> Completion.values([text])}

        expected = json(CompleteResult.build(struct))

        assert json_map("completion/complete", atom_map) == expected
        assert json_map("completion/complete", string_map) == expected
        assert json_map("completion/complete", struct_completion_map) == expected
      end
    end
  end

  # A nested map of a block (annotations, icons, resource) is checked
  # with its struct and the block goes to the client as it is.
  #
  describe "a block with nested maps passes" do
    test "a text block with annotations, in the three forms" do
      block = %{type: "text", text: "x", annotations: %{priority: 1}}
      string_block = %{"type" => "text", "text" => "x", "annotations" => %{"priority" => 1}}

      assert {:ok, built} = Result.normalize("tools/call", %{content: [block]})
      assert built.content == [block]

      assert {:ok, built} = Result.normalize("tools/call", %{"content" => [string_block]})
      assert built.content == [string_block]

      struct_result = %CallToolResult{} |> CallToolResult.content([block])
      assert CallToolResult.build(struct_result).content == [block]
    end

    test "an embedded resource block with annotations and a text resource, in the three forms" do
      block = %{
        type: "resource",
        resource: %{uri: "file:///a", text: "x"},
        annotations: %{priority: 0.5}
      }

      string_block = %{
        "type" => "resource",
        "resource" => %{"uri" => "file:///a", "text" => "x"},
        "annotations" => %{"priority" => 0.5}
      }

      assert {:ok, built} = Result.normalize("tools/call", %{content: [block]})
      assert built.content == [block]

      assert {:ok, built} = Result.normalize("tools/call", %{"content" => [string_block]})
      assert built.content == [string_block]

      struct_result = %CallToolResult{} |> CallToolResult.content([block])
      assert CallToolResult.build(struct_result).content == [block]
    end

    test "a resource link block with icons, in the three forms" do
      block = %{
        type: "resource_link",
        uri: "file:///a",
        name: "a",
        icons: [%{src: "https://x/i.png"}]
      }

      string_block = %{
        "type" => "resource_link",
        "uri" => "file:///a",
        "name" => "a",
        "icons" => [%{"src" => "https://x/i.png"}]
      }

      assert {:ok, built} = Result.normalize("tools/call", %{content: [block]})
      assert built.content == [block]

      assert {:ok, built} = Result.normalize("tools/call", %{"content" => [string_block]})
      assert built.content == [string_block]

      struct_result = %CallToolResult{} |> CallToolResult.content([block])
      assert CallToolResult.build(struct_result).content == [block]
    end

    test "a message content with annotations, in the three forms" do
      content = %{type: "text", text: "x", annotations: %{priority: 0.5}}

      string_content = %{"type" => "text", "text" => "x", "annotations" => %{"priority" => 0.5}}

      message = %{role: "user", content: content}
      string_message = %{"role" => "user", "content" => string_content}

      assert {:ok, built} = Result.normalize("prompts/get", %{messages: [message]})
      assert built.messages == [message]

      assert {:ok, built} = Result.normalize("prompts/get", %{"messages" => [string_message]})
      assert built.messages == [string_message]

      struct_result = %GetPromptResult{} |> GetPromptResult.messages([message])
      assert GetPromptResult.build(struct_result).messages == [message]
    end

    test "a bad nested value gives an error and not a crash" do
      assert {:error, reason} =
               Result.normalize("tools/call", %{
                 content: [%{type: "text", text: "x", annotations: %{priority: "high"}}]
               })

      assert reason =~ "priority"

      assert {:error, reason} =
               Result.normalize("tools/call", %{
                 content: [
                   %{
                     type: "resource_link",
                     uri: "file:///a",
                     name: "a",
                     icons: [%{mimeType: "image/png"}]
                   }
                 ]
               })

      assert reason =~ "src"
    end

    test "a nested value of the wrong struct kind is an error that names it" do
      assert {:error, reason} =
               Result.normalize("tools/call", %{
                 content: [%{type: "text", text: "x", annotations: %Icon{}}]
               })

      assert reason =~ "annotations must be a OzMcp.Structs.Annotations"

      assert {:error, reason} =
               Result.normalize("tools/call", %{
                 content: [%{type: "resource", resource: %Icon{}}]
               })

      assert reason =~ "resource must be a map"
    end
  end

  # An annotations map with no known member passes and so does a map
  # whose members are all missing or nil: the block goes to the client
  # as it is. A struct with each field nil keeps its rule and an
  # improper list is an error.
  #
  describe "an annotations map with no known member and an improper list" do
    test "an empty or unknown-only annotations map passes, in the three forms" do
      for annotations <- [%{}, %{foo: 1}] do
        block = %{type: "text", text: "x", annotations: annotations}
        string_block = %{"type" => "text", "text" => "x", "annotations" => annotations}

        assert {:ok, built} = Result.normalize("tools/call", %{content: [block]})
        assert json(built) == json(%{content: [block]})

        assert {:ok, built} = Result.normalize("tools/call", %{"content" => [string_block]})
        assert json(built) == json(%{"content" => [string_block]})

        struct_result = %CallToolResult{} |> CallToolResult.content([block])
        assert json(CallToolResult.build(struct_result)) == json(%{content: [block]})
      end
    end

    test "annotations with a member nil passes, in both key forms, as it goes to the wire" do
      atom_block = %{type: "text", text: "x", annotations: %{priority: nil}}
      string_block = %{"type" => "text", "text" => "x", "annotations" => %{"priority" => nil}}

      assert {:ok, built} = Result.normalize("tools/call", %{content: [atom_block]})
      assert json(built) == json(%{content: [atom_block]})

      assert {:ok, built} = Result.normalize("tools/call", %{"content" => [string_block]})
      assert json(built) == json(%{"content" => [string_block]})

      struct_result = %CallToolResult{} |> CallToolResult.content([atom_block])
      assert json(CallToolResult.build(struct_result)) == json(%{content: [atom_block]})
    end

    test "annotations with one bad member still fails" do
      assert {:error, reason} =
               Result.normalize("tools/call", %{
                 content: [%{type: "text", text: "x", annotations: %{priority: nil, audience: 1}}]
               })

      assert reason =~ "audience"
    end

    test "a struct block with empty annotations gives -32603 and no crash log" do
      log =
        capture_log(fn ->
          assert {:error, error} =
                   Invoke.run(context("tools/call"), fn ->
                     {:ok, %{content: [%TextContent{text: "x", annotations: %Annotations{}}]}}
                   end)

          assert error.code == -32603
        end)

      assert log =~ "bad result"
      refute log =~ "user callback crashed"
    end

    test "an improper content gives -32603 and no crash log" do
      assert_bad_result("tools/call", %{content: [%{type: "text", text: "x"} | 5]})
    end

    test "an improper contents gives -32603 and no crash log" do
      assert_bad_result("resources/read", %{contents: [%{uri: "file:///a", text: "x"} | 5]})
    end

    test "improper messages give -32603 and no crash log" do
      assert_bad_result("prompts/get", %{
        messages: [%{role: "user", content: %{type: "text", text: "x"}} | 5]
      })
    end
  end

  # The uri of a read item, of an embedded resource and of a
  # resource_link block in a callback result must be a non-empty string
  # only: a relative uri passes and goes to the client as it is.
  #
  describe "a relative uri in a callback result passes" do
    test "a read item, for a map and for a struct result" do
      assert {:ok, built} =
               Result.normalize("resources/read", %{contents: [%{uri: "notes/1", text: "x"}]})

      assert json(built) == json(%{contents: [%{uri: "notes/1", text: "x"}]})

      struct_result =
        %ReadResourceResult{}
        |> ReadResourceResult.contents([
          %TextResourceContents{}
          |> TextResourceContents.uri("notes/1")
          |> TextResourceContents.text("x")
        ])

      assert json(ReadResourceResult.build(struct_result)) ==
               json(%{contents: [%{uri: "notes/1", text: "x"}]})
    end

    test "an embedded resource and a resource_link block, for a map and for a struct result" do
      assert {:ok, built} =
               Result.normalize("tools/call", %{
                 content: [%{type: "resource", resource: %{uri: "notes/1", text: "x"}}]
               })

      assert json(built) ==
               json(%{content: [%{type: "resource", resource: %{uri: "notes/1", text: "x"}}]})

      assert {:ok, built} =
               Result.normalize("tools/call", %{
                 content: [%{type: "resource_link", uri: "notes/1", name: "a"}]
               })

      assert json(built) ==
               json(%{content: [%{type: "resource_link", uri: "notes/1", name: "a"}]})

      struct_result =
        %CallToolResult{}
        |> CallToolResult.content([
          %EmbeddedResource{resource: %TextResourceContents{uri: "notes/1", text: "x"}},
          %ResourceLink{uri: "notes/1", name: "a"}
        ])

      assert json(CallToolResult.build(struct_result)) ==
               json(%{
                 content: [
                   %{type: "resource", resource: %{uri: "notes/1", text: "x"}},
                   %{type: "resource_link", uri: "notes/1", name: "a"}
                 ]
               })
    end

    test "an empty or missing uri still gives an error, for a map and for a struct result" do
      for method_result <- [
            {"resources/read", %{contents: [%{text: "x"}]}},
            {"resources/read", %{contents: [%{uri: "", text: "x"}]}},
            {"tools/call", %{content: [%{type: "resource", resource: %{text: "x"}}]}},
            {"tools/call", %{content: [%{type: "resource_link", name: "a"}]}},
            {"tools/call", %{content: [%{type: "resource_link", uri: "", name: "a"}]}}
          ] do
        {method, result} = method_result
        assert {:error, _} = Result.normalize(method, result)
      end

      assert {:error, _} =
               Result.normalize("resources/read", %{
                 contents: [struct(TextResourceContents, uri: "", text: "x")]
               })

      assert {:error, _} =
               Result.normalize("tools/call", %{
                 content: [struct(ResourceLink, uri: "", name: "a")]
               })
    end
  end

  defp assert_bad_result(method, value) do
    log =
      capture_log(fn ->
        assert {:error, error} = Invoke.run(context(method), fn -> {:ok, value} end)
        assert error.code == -32603
      end)

    assert log =~ "must be a list"
    refute log =~ "user callback crashed"
  end

  defp context(method) do
    %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: method}
  end

  # The decoded JSON ignores the order and the key form: two results are
  # the same when the client sees the same JSON object.
  #
  defp json(map), do: map |> JSON.encode!() |> JSON.decode!()

  defp json_map(method, map) do
    {:ok, built} = Result.normalize(method, map)
    json(built)
  end

  defp error(method, map) do
    {:error, reason} = Result.normalize(method, map)
    reason
  end
end
