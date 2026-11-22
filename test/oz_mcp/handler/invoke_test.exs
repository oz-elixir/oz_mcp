defmodule OzMcp.Handler.InvokeTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias OzMcp.Context
  alias OzMcp.Handler.Invoke
  alias OzMcp.PostStream
  alias OzMcp.Session
  alias OzMcp.Sessions
  alias Support.Helpers.Utils
  alias Support.Servers

  alias Support.Helpers.{TelemetryCapture, TreeProbe}

  alias OzMcp.Structs.{
    CallToolResult,
    CompleteResult,
    Completion,
    GetPromptResult,
    PromptMessage,
    ReadResourceResult,
    TextContent,
    TextResourceContents
  }

  alias OzMcp.Utils.Error

  @server_module Servers.TasksTest

  @server Module.concat(@server_module, __MODULE__)

  # Never started in this test module: its invoke supervisor does not
  # exist, so the callback runs inline, behind the crash guards.
  #
  @inline_server Servers.ToolsOnly

  describe "inline execution (the runtime of the server is not running)" do
    test "passes an {:ok, value} result through" do
      assert Invoke.run(%{instance: @inline_server, server: @inline_server}, fn -> {:ok, 42} end) ==
               {:ok, 42}
    end

    test "passes an {:error, %Error{}} result through" do
      error = Error.new(-32000, "boom")

      assert Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
               {:error, error}
             end) ==
               {:error, error}
    end

    test "passes an {:error, plain map} result through" do
      error = %{code: -32000, message: "boom", data: %{"k" => "v"}}

      assert Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
               {:error, error}
             end) ==
               {:error, error}
    end

    test "fills a missing data key on plain-map errors" do
      assert Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
               {:error, %{code: -32000, message: "boom"}}
             end) == {:error, %{code: -32000, message: "boom", data: nil}}
    end

    test "accepts a %OzMcp.Context{} as ctx" do
      context = Context.new(@inline_server, :http_streamable, :rpc)

      assert Invoke.run(context, fn -> {:ok, :done} end) == {:ok, :done}
    end

    @tag :capture_log
    test "rescues a raise and returns a generic -32603" do
      assert {:error, error} =
               Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                 raise "secret details"
               end)

      assert error.code == -32603
      assert error.message == "internal error"
      refute error.message =~ "secret"
    end

    @tag :capture_log
    test "rescues a throw" do
      assert {:error, error} =
               Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                 throw(:boom)
               end)

      assert error.code == -32603
      assert error.message == "internal error"
    end

    @tag :capture_log
    test "rescues an exit" do
      assert {:error, error} =
               Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                 exit(:boom)
               end)

      assert error.code == -32603
      assert error.message == "internal error"
    end

    @tag :capture_log
    test "rejects an unexpected callback return value" do
      assert {:error, error} =
               Invoke.run(%{instance: @inline_server, server: @inline_server}, fn -> :ok end)

      assert error.code == -32603
      assert error.message == "internal error"
    end

    @tag :capture_log
    test "rejects an {:error, atom} result that cannot be encoded" do
      assert {:error, error} =
               Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                 {:error, :no_tool}
               end)

      assert error.code == -32603
      assert error.message == "internal error"
    end

    @tag :capture_log
    test "an error with data that is not JSON becomes -32603" do
      assert {:error, error} =
               Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                 {:error, Error.new(-32000, "boom", self())}
               end)

      assert error.code == -32603
      assert error.message == "internal error"

      assert {:error, %{code: -32603}} =
               Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                 {:error, %{code: -32000, message: "boom", data: self()}}
               end)
    end

    test "an error with data that is JSON passes through" do
      error = Error.new(-32000, "boom", %{"k" => [1, 2]})

      assert Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
               {:error, error}
             end) ==
               {:error, error}
    end

    test "refuses the codes of the framework and logs a warning" do
      for code <- [-32800, -32600] do
        log =
          capture_log(fn ->
            assert {:error, error} =
                     Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                       {:error, Error.new(code, "mine")}
                     end)

            assert error.code == -32603
            assert error.message == "internal error"
          end)

        assert log =~ "reserved error code #{code}"
      end
    end

    @tag :capture_log
    test "a result that is not a map is refused for the methods that give a result struct" do
      for method <- ["tools/call", "resources/read", "prompts/get", "completion/complete"] do
        context = %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: method}

        assert {:error, %{code: -32603}} = Invoke.run(context, fn -> {:ok, "text"} end)
      end
    end

    @tag :capture_log
    test "a map without the member of the result is refused" do
      for {method, key, valid} <- [
            {"tools/call", "content", []},
            {"resources/read", "contents", []},
            {"prompts/get", "messages", []},
            {"completion/complete", "completion", %{"values" => []}}
          ] do
        context = %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: method}

        assert {:error, %{code: -32603}} = Invoke.run(context, fn -> {:ok, %{}} end)
        assert {:ok, _} = Invoke.run(context, fn -> {:ok, %{key => valid}} end)
        assert {:ok, _} = Invoke.run(context, fn -> {:ok, %{String.to_atom(key) => valid}} end)
      end
    end

    @tag :capture_log
    test "a tools/call map with a bad content and a bad isError is refused" do
      context = %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: "tools/call"}

      log =
        capture_log(fn ->
          assert {:error, %{code: -32603, message: "internal error"}} =
                   Invoke.run(context, fn ->
                     {:ok, %{"content" => "not a list", "isError" => "maybe"}}
                   end)
        end)

      assert log =~ "tools/call"
      assert log =~ "The 'content' field must be a list"
      #
      # the value of the result is not in the log
      #
      refute log =~ "maybe"
    end

    @tag :capture_log
    test "a resources/read map with a content block without a uri is refused" do
      context =
        %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: "resources/read"}

      assert {:error, %{code: -32603, message: "internal error"}} =
               Invoke.run(context, fn -> {:ok, %{"contents" => [%{"text" => "x"}]}} end)
    end

    @tag :capture_log
    test "a prompts/get map with a string in messages is refused" do
      context = %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: "prompts/get"}

      assert {:error, %{code: -32603, message: "internal error"}} =
               Invoke.run(context, fn -> {:ok, %{"messages" => ["hello"]}} end)
    end

    @tag :capture_log
    test "a completion/complete map with more than 100 values is refused" do
      context =
        %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: "completion/complete"}

      values = Enum.map(1..101, &Integer.to_string/1)

      assert {:error, %{code: -32603, message: "internal error"}} =
               Invoke.run(context, fn -> {:ok, %{"completion" => %{"values" => values}}} end)
    end

    @tag :capture_log
    test "an unknown member of a shaped map result that is not JSON is refused" do
      context = %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: "tools/call"}

      assert {:error, %{code: -32603, message: "internal error"}} =
               Invoke.run(context, fn -> {:ok, %{1 => "x", content: []}} end)
    end

    @tag :capture_log
    test "a duplicate key in a map result is refused and the log names the path" do
      context = %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: "tools/call"}
      parent = self()

      log =
        capture_log(fn ->
          assert {:error, %{code: -32603}} =
                   Invoke.run(
                     context,
                     fn ->
                       {:ok, %{content: [], structuredContent: %{"a" => 1, a: 2}}}
                     end,
                     check: fn _ -> send(parent, :check_called) && :ok end
                   )
        end)

      assert log =~ "structuredContent"
      refute_received :check_called
    end

    @tag :capture_log
    test "a duplicate key in a CallToolResult struct is refused and the log names the path" do
      context = %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: "tools/call"}

      log =
        capture_log(fn ->
          assert {:error, %{code: -32603}} =
                   Invoke.run(context, fn ->
                     {:ok, %CallToolResult{structuredContent: %{"a" => 1, a: 2}, content: []}}
                   end)
        end)

      assert log =~ "structuredContent"
    end

    @tag :capture_log
    test "a CompleteResult struct with a bad plain-map completion is refused" do
      context =
        %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: "completion/complete"}

      values = Enum.map(1..101, &Integer.to_string/1)

      log =
        capture_log(fn ->
          assert {:error, %{code: -32603, message: "internal error"}} =
                   Invoke.run(context, fn ->
                     {:ok, %CompleteResult{completion: %{values: values}}}
                   end)
        end)

      assert log =~ "The 'values' field must contain at most 100 items"

      for completion <- [%{"values" => [1]}, %{"values" => "a"}, %{"total" => 3}] do
        assert {:error, %{code: -32603}} =
                 Invoke.run(context, fn -> {:ok, %CompleteResult{completion: completion}} end)
      end
    end

    test "a CompleteResult struct with a valid completion passes" do
      context =
        %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: "completion/complete"}

      for completion <- [
            %{"values" => ["a"], "total" => 1},
            %{values: Enum.map(1..100, &Integer.to_string/1)},
            %Completion{} |> Completion.values(["a"])
          ] do
        assert {:ok, %{completion: _}} =
                 Invoke.run(context, fn -> {:ok, %CompleteResult{completion: completion}} end)
      end
    end

    test "a built result returned as a map passes the check" do
      tool_result =
        %CallToolResult{}
        |> CallToolResult.content([%TextContent{} |> TextContent.text("x")])
        |> CallToolResult.is_error(false)
        |> CallToolResult.extras(%{"durationMs" => 12})
        |> CallToolResult.build()

      resource_result =
        %ReadResourceResult{}
        |> ReadResourceResult.contents([
          %TextResourceContents{}
          |> TextResourceContents.uri("file:///a")
          |> TextResourceContents.text("x")
        ])
        |> ReadResourceResult.build()

      prompt_result =
        %GetPromptResult{}
        |> GetPromptResult.messages([
          %PromptMessage{role: :user, content: %TextContent{} |> TextContent.text("x")}
        ])
        |> GetPromptResult.build()

      completion_result =
        %CompleteResult{}
        |> CompleteResult.completion(%Completion{} |> Completion.values(["a"]))
        |> CompleteResult.build()

      for {method, result} <- [
            {"tools/call", tool_result},
            {"resources/read", resource_result},
            {"prompts/get", prompt_result},
            {"completion/complete", completion_result}
          ] do
        context = %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: method}

        assert {:ok, _} = Invoke.run(context, fn -> {:ok, result} end)
      end
    end

    test "a method of the framework takes any JSON map" do
      context = %{
        Context.new(@inline_server, :http_streamable, :rpc)
        | rpc_method: "tasks/result"
      }

      assert Invoke.run(context, fn -> {:ok, %{}} end) == {:ok, %{}}
    end

    @tag :capture_log
    test "a map result with a bad top-level _meta key is refused" do
      context = %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: "tools/call"}

      log =
        capture_log(fn ->
          assert {:error, %Error{code: -32603, message: "internal error"}} =
                   Invoke.run(context, fn ->
                     {:ok, %{"content" => [], "_meta" => %{"my key" => 1}}}
                   end)
        end)

      assert log =~ "user callback returned a bad result for tools/call"
      assert log =~ "my key"
    end

    @tag :capture_log
    test "a map result with a bad top-level _meta atom key is refused" do
      context = %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: "tools/call"}

      assert {:error, %Error{code: -32603, message: "internal error"}} =
               Invoke.run(context, fn ->
                 {:ok, %{content: [], _meta: %{:"-a" => 1}}}
               end)
    end

    @tag :capture_log
    test "a map result with a reserved _meta prefix is refused" do
      context = %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: "tools/call"}

      assert {:error, %Error{code: -32603}} =
               Invoke.run(context, fn ->
                 {:ok, %{"content" => [], "_meta" => %{"io.modelcontextprotocol/x" => 1}}}
               end)

      assert {:error, %Error{code: -32603}} =
               Invoke.run(context, fn ->
                 {:ok, %{content: [], _meta: %{"dev.mcp/x" => 1}}}
               end)
    end

    test "a map result accepts a key of the framework and a good key" do
      context = %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: "tools/call"}

      assert {:ok, _} =
               Invoke.run(context, fn ->
                 {:ok,
                  %{
                    "content" => [],
                    "_meta" => %{
                      "io.modelcontextprotocol/related-task" => %{"taskId" => "t1"},
                      "com.example/revision" => "2"
                    }
                  }}
               end)
    end

    test "a _meta under a nested map of the result is not checked" do
      context = %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: "tools/call"}

      # The type of the block names no content struct, so the block is
      # not built and its _meta is not checked.
      #
      assert {:ok, _} =
               Invoke.run(context, fn ->
                 {:ok,
                  %{
                    "content" => [
                      %{
                        "type" => "com.example/widget",
                        "text" => "ok",
                        "_meta" => %{"io.modelcontextprotocol/x" => 1}
                      }
                    ]
                  }}
               end)
    end

    test "a _meta under a content block with a known type is checked" do
      context = %{Context.new(@inline_server, :http_streamable, :rpc) | rpc_method: "tools/call"}

      assert {:error, %{code: -32603}} =
               Invoke.run(context, fn ->
                 {:ok,
                  %{
                    "content" => [
                      %{
                        "type" => "text",
                        "text" => "ok",
                        "_meta" => %{"io.modelcontextprotocol/x" => 1}
                      }
                    ]
                  }}
               end)
    end

    test "the check of the result runs in the guard" do
      ok =
        Invoke.run(
          %{instance: @inline_server, server: @inline_server},
          fn -> {:ok, %{"a" => 1}} end,
          check: fn _ -> :ok end
        )

      assert ok == {:ok, %{"a" => 1}}

      assert {:error, %{code: -32603, data: ["bad"]}} =
               Invoke.run(
                 %{instance: @inline_server, server: @inline_server},
                 fn -> {:ok, %{}} end,
                 check: fn _ -> {:error, ["bad"]} end
               )
    end

    @tag :capture_log
    test "a check that raises gives -32603" do
      assert {:error, error} =
               Invoke.run(
                 %{instance: @inline_server, server: @inline_server},
                 fn -> {:ok, %{}} end,
                 check: fn _ -> raise "boom" end
               )

      assert error.code == -32603
      assert error.message == "internal error"
    end

    test "isolation: :inline runs the callback in the calling process" do
      parent = self()

      assert Invoke.run(
               %{instance: @server, server: @server_module},
               fn ->
                 send(parent, {:ran_in, self()})
                 {:ok, :done}
               end,
               isolation: :inline
             ) == {:ok, :done}

      assert_received {:ran_in, ^parent}
    end

    test "an explicit :infinity timeout keeps the inline guards" do
      assert Invoke.run(
               %{instance: @inline_server, server: @inline_server},
               fn -> {:ok, :done} end,
               timeout: :infinity
             ) ==
               {:ok, :done}

      assert {:error, error} =
               Invoke.run(
                 %{instance: @inline_server, server: @inline_server},
                 fn -> raise "boom" end,
                 timeout: :infinity
               )

      assert error.code == -32603
    end
  end

  describe "silent and logged downgrades to inline execution" do
    test "the runtime is not started: silent" do
      log =
        Utils.capture_log(fn ->
          assert Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                   {:ok, :done}
                 end) == {:ok, :done}
        end)

      assert log == ""
    end

    test "isolation: :inline with a running instance: warning" do
      start_runtime(%{})

      log =
        capture_log(fn ->
          assert Invoke.run(%{instance: @server, server: @server_module}, fn -> {:ok, :done} end,
                   isolation: :inline
                 ) ==
                   {:ok, :done}
        end)

      assert log =~ "[warning]"
      assert log =~ "isolation: :inline"
      assert log =~ "without deadline"
    end

    test "a supervised run is not reported" do
      start_runtime(%{})

      log =
        Utils.capture_log(fn ->
          assert Invoke.run(%{instance: @server, server: @server_module}, fn -> {:ok, :done} end) ==
                   {:ok, :done}
        end)

      assert log == ""
    end

    test "a running instance with no invoke supervisor: error, warning and crashed telemetry" do
      start_runtime(%{})
      parent = self()
      workers = TreeProbe.workers(@server)
      calls_id = {OzMcp.Instance.names(@server), :calls}
      :ok = Supervisor.terminate_child(workers, calls_id)
      ref = TelemetryCapture.attach()

      log =
        capture_log(fn ->
          assert {:error, %Error{code: -32603, message: "internal error"}} =
                   Invoke.run(%{instance: @server, server: @server_module}, fn ->
                     send(parent, :callback_ran)
                     {:ok, :done}
                   end)
        end)

      refute_received :callback_ran

      assert log =~ "[warning]"
      assert log =~ "invoke supervisor of #{inspect(@server)} is not running"

      stop =
        ref
        |> TelemetryCapture.drain_wait(@server, 200)
        |> Enum.find(fn {name, _measurements, _meta} -> name == [:oz_mcp, :callback, :stop] end)

      assert {_name, _measurements, %{result: :crashed, error_code: -32603}} = stop
    end

    test "an invoke supervisor without registered execution opts: warning, defaults" do
      server = TestServerWithoutRegistration
      {:ok, _} = Registry.start_link(keys: :unique, name: OzMcp.Instance.names(server))
      {:ok, _} = Task.Supervisor.start_link(name: OzMcp.Instance.via(server, :calls))
      parent = self()

      log =
        capture_log(fn ->
          assert Invoke.run(%{instance: server, server: server}, fn ->
                   send(parent, {:ran_in, self()})
                   {:ok, :done}
                 end) == {:ok, :done}
        end)

      # Still supervised, with the defaults.
      #
      assert_received {:ran_in, runner}
      assert runner != parent
      assert log =~ "execution options of #{inspect(server)} are not available"
      assert log =~ "no deadline"
    end
  end

  describe "callback result building and encodability (inline)" do
    test "builds an unbuilt %CallToolResult{} with unbuilt content" do
      assert {:ok, result} =
               Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                 {:ok,
                  %CallToolResult{}
                  |> CallToolResult.content([
                    %TextContent{} |> TextContent.text("22/11/2025")
                  ])}
               end)

      assert result == %{content: [%{type: "text", text: "22/11/2025"}]}
      refute Map.has_key?(result, :__struct__)
    end

    test "builds an unbuilt %ReadResourceResult{} with unbuilt contents" do
      assert {:ok, result} =
               Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                 {:ok,
                  %ReadResourceResult{}
                  |> ReadResourceResult.contents([
                    %TextResourceContents{}
                    |> TextResourceContents.uri("file:///logs/app.log")
                    |> TextResourceContents.text("INFO App started")
                  ])}
               end)

      assert result == %{contents: [%{uri: "file:///logs/app.log", text: "INFO App started"}]}
      refute Map.has_key?(result, :__struct__)
    end

    test "builds an unbuilt %GetPromptResult{} with unbuilt messages" do
      assert {:ok, result} =
               Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                 {:ok,
                  %GetPromptResult{}
                  |> GetPromptResult.messages([
                    %PromptMessage{
                      role: :user,
                      content: %TextContent{} |> TextContent.text("Review this code.")
                    }
                  ])}
               end)

      assert result == %{
               messages: [
                 %{"role" => "user", "content" => %{type: "text", text: "Review this code."}}
               ]
             }
    end

    test "builds an unbuilt %CompleteResult{} with an unbuilt completion" do
      assert {:ok, result} =
               Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                 {:ok,
                  %CompleteResult{}
                  |> CompleteResult.completion(
                    %Completion{}
                    |> Completion.values(["python", "pytorch"])
                  )}
               end)

      assert result == %{completion: %{values: ["python", "pytorch"]}}
    end

    test "passes through an already-built result map" do
      built =
        %CallToolResult{}
        |> CallToolResult.content([%TextContent{} |> TextContent.text("hi")])
        |> CallToolResult.build()

      assert Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
               {:ok, built}
             end) == {:ok, built}
    end

    @tag :capture_log
    test "rejects a struct that is not a result struct" do
      assert {:error, error} =
               Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                 {:ok, Date.utc_today()}
               end)

      assert error.code == -32603
      assert error.message == "internal error"
    end

    @tag :capture_log
    test "rejects a payload hiding an unbuilt struct" do
      assert {:error, error} =
               Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                 {:ok, %{"content" => %TextContent{} |> TextContent.text("hi")}}
               end)

      assert error.code == -32603
    end

    @tag :capture_log
    test "rejects a term the JSON encoder cannot represent" do
      assert {:error, error} =
               Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                 {:ok, {:tuple, 1}}
               end)

      assert error.code == -32603
      assert error.message == "internal error"
    end

    @tag :capture_log
    test "rejects an improper list" do
      assert {:error, error} =
               Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                 {:ok, [1 | 2]}
               end)

      assert error.code == -32603
    end

    @tag :capture_log
    test "rejects a map keyed by a non-string term" do
      assert {:error, error} =
               Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                 {:ok, %{1 => "one"}}
               end)

      assert error.code == -32603
    end

    @tag :capture_log
    test "rejects a result struct that fails its build validation" do
      assert {:error, error} =
               Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                 {:ok, %CallToolResult{} |> CallToolResult.content(:garbage)}
               end)

      assert error.code == -32603
      assert error.message == "internal error"
    end

    @tag :capture_log
    test "the log names the path and the struct of an invalid term" do
      log =
        capture_log(fn ->
          assert {:error, %Error{code: -32603, message: "internal error", data: nil}} =
                   Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                     {:ok, %{"structuredContent" => %{"created_at" => ~U[2026-10-07 10:00:00Z]}}}
                   end)
        end)

      assert log =~ "structuredContent.created_at"
      assert log =~ "DateTime"
    end

    @tag :capture_log
    test "the log names the index of an invalid list item" do
      log =
        capture_log(fn ->
          assert {:error, %Error{code: -32603, message: "internal error", data: nil}} =
                   Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                     {:ok, %{"content" => [%{"type" => "text", "text" => "ok"}, {:tuple}]}}
                   end)
        end)

      assert log =~ "content[1]"
      assert log =~ "is not a JSON term"
    end

    @tag :capture_log
    test "the log names a map key that is not an atom or a string" do
      log =
        capture_log(fn ->
          assert {:error, %Error{code: -32603, message: "internal error", data: nil}} =
                   Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                     {:ok, %{1 => "x"}}
                   end)
        end)

      assert log =~ "map key 1 is not an atom or a string"
    end

    @tag :capture_log
    test "the log names the root of the result for a root-level invalid term" do
      log =
        capture_log(fn ->
          assert {:error, %Error{code: -32603}} =
                   Invoke.run(%{instance: @inline_server, server: @inline_server}, fn ->
                     {:ok, Date.utc_today()}
                   end)
        end)

      assert log =~ "at the root of the result"
      assert log =~ "struct Date"
    end
  end

  describe "supervised execution with a deadline (request_timeout_ms configured)" do
    setup do
      Utils.start_instance(
        @server_module,
        [name: @server] ++ Map.to_list(%{request_timeout_ms: 200})
      )

      %{ctx: %{instance: @server, server: @server_module}}
    end

    test "returns the callback result before the deadline", %{ctx: ctx} do
      assert Invoke.run(ctx, fn -> {:ok, :fast} end) == {:ok, :fast}
    end

    test "builds an unbuilt result struct before the deadline", %{ctx: ctx} do
      assert {:ok, result} =
               Invoke.run(ctx, fn ->
                 {:ok,
                  %CallToolResult{}
                  |> CallToolResult.content([%TextContent{} |> TextContent.text("fast")])}
               end)

      assert result == %{content: [%{type: "text", text: "fast"}]}
    end

    @tag :capture_log
    test "rejects a result the JSON encoder cannot represent", %{ctx: ctx} do
      #
      # A generous deadline: the encode rejection must win the race, the
      # deadline path has its own test below.
      #
      assert {:error, error} = Invoke.run(ctx, fn -> {:ok, self()} end, timeout: 5_000)

      assert error.code == -32603
      assert error.message == "internal error"
    end

    @tag :capture_log
    test "rejects a result struct that fails its build validation", %{ctx: ctx} do
      assert {:error, error} =
               Invoke.run(ctx, fn -> {:ok, %CompleteResult{}} end, timeout: 5_000)

      assert error.code == -32603
      assert error.message == "internal error"
    end

    @tag :capture_log
    test "rejects a map result with a reserved top-level _meta prefix", %{ctx: ctx} do
      assert {:error, %Error{code: -32603, message: "internal error"}} =
               Invoke.run(ctx, fn ->
                 {:ok, %{"content" => [], "_meta" => %{"io.modelcontextprotocol/x" => 1}}}
               end)
    end

    @tag :capture_log
    test "kills a hanging callback at the deadline and returns -32603", %{ctx: ctx} do
      {duration_us, result} =
        :timer.tc(fn ->
          #
          # The callback simulates work that never ends: the deadline stops it.
          #
          Invoke.run(ctx, fn -> Process.sleep(30_000) end)
        end)

      assert {:error, error} = result
      assert error.code == -32603
      assert error.message == "request execution timed out"
      assert error.data == %{"reason" => "timeout"}

      # The deadline (200 ms) is honoured: no hanging connection.
      #
      assert duration_us < 5_000_000
    end

    @tag :capture_log
    test "rescues a crash inside the supervised task", %{ctx: ctx} do
      assert {:error, error} =
               Invoke.run(ctx, fn -> raise "secret details" end, timeout: 5_000)

      assert error.code == -32603
      assert error.message == "internal error"
      refute error.message =~ "secret"

      # A crash never carries the timeout reason: the client can tell
      # a deadline overrun apart from a real internal error.
      #
      assert is_nil(error.data)
    end

    @tag :capture_log
    test "rejects an unexpected callback return value", %{ctx: ctx} do
      assert {:error, error} = Invoke.run(ctx, fn -> :garbage end, timeout: 5_000)

      assert error.code == -32603
      assert error.message == "internal error"
    end
  end

  describe "supervised execution without a deadline" do
    setup do
      start_runtime(%{})
      :ok
    end

    test "the callback runs in its own process, not in the caller" do
      parent = self()

      assert {:ok, :done} =
               Invoke.run(%{instance: @server, server: @server_module}, fn ->
                 send(parent, {:ran_in, self()})
                 {:ok, :done}
               end)

      assert_received {:ran_in, runner}
      assert runner != parent
    end

    test "a callback may run for as long as it needs" do
      assert {:ok, :slow} =
               Invoke.run(%{instance: @server, server: @server_module}, fn ->
                 #
                 # The callback simulates slow work: no runtime limit stops it.
                 #
                 Process.sleep(300)
                 {:ok, :slow}
               end)
    end

    @tag :capture_log
    test "a crash is reported as -32603" do
      assert {:error, %Error{code: -32603, message: "internal error", data: nil}} =
               Invoke.run(%{instance: @server, server: @server_module}, fn -> raise "boom" end)
    end

    test "a per call :timeout overrides the runtime" do
      assert {:error, %Error{code: -32603, data: %{"reason" => "timeout"}}} =
               Invoke.run(
                 %{instance: @server, server: @server_module},
                 #
                 # The callback simulates work that outlives the deadline of 50 ms.
                 #
                 fn -> Process.sleep(5_000) end,
                 timeout: 50
               )
    end

    test "an invalid :timeout raises" do
      assert_raise ArgumentError, ~r/timeout must be a positive integer/, fn ->
        Invoke.run(%{instance: @server, server: @server_module}, fn -> {:ok, 1} end, timeout: -5)
      end
    end
  end

  describe "messages for the stream of the request" do
    setup do
      start_runtime(%{request_timeout_ms: 300})
      :ok
    end

    @tag :capture_log
    test "are written on the stream while the caller waits" do
      {:ok, stream} = Utils.begin_stream(@server, "s1", 7, Plug.Test.conn(:post, "/"), & &1)
      ctx = %{instance: @server, server: @server_module, session_id: "s1", request_id: 7}

      {{:ok, :done}, stream} =
        Invoke.run(
          ctx,
          fn ->
            PostStream.route(@server, "s1", 7, %{"method" => "ping"})
            #
            # The callback keeps working after the message: the owner gets it.
            #
            Process.sleep(50)
            {:ok, :done}
          end,
          stream: stream
        )

      assert {{:streamed, conn}, _stream} = PostStream.answer(%{"id" => 7}, stream)
      assert conn.resp_body =~ ~s("method":"ping")
    end

    test "an inline callback that owns the stream queues the message for the answer" do
      parent = self()

      {:ok, stream} =
        Utils.begin_stream(@server, "s1", 7, Plug.Test.conn(:post, "/"), fn conn ->
          send(parent, :stream_started)
          conn
        end)

      ctx = %{instance: @server, server: @server_module, session_id: "s1", request_id: 7}

      {{:ok, :done}, stream} =
        Invoke.run(
          ctx,
          fn ->
            PostStream.route(@server, "s1", 7, %{"method" => "ping"})
            #
            # Nothing is written while the callback runs: the message waits
            # for the wait loop or the answer of the request.
            #
            refute_received :stream_started
            {:ok, :done}
          end,
          isolation: :inline,
          stream: stream
        )

      assert {{:streamed, conn}, _stream} = PostStream.answer(%{"id" => 7}, stream)
      assert conn.resp_body =~ ~s("method":"ping")
    end

    test "the wait goes on after a message" do
      {:ok, stream} = Utils.begin_stream(@server, "s1", 7, Plug.Test.conn(:post, "/"), & &1)
      ctx = %{instance: @server, server: @server_module, session_id: "s1", request_id: 7}

      {{:ok, :late}, stream} =
        Invoke.run(
          ctx,
          fn ->
            PostStream.route(@server, "s1", 7, %{"method" => "ping"})
            #
            # The callback keeps working after the message, past its deadline.
            #
            Process.sleep(100)
            {:ok, :late}
          end,
          timeout: :infinity,
          stream: stream
        )

      PostStream.close(stream)
    end

    @tag :capture_log
    test "do not move the deadline" do
      {:ok, stream} = Utils.begin_stream(@server, "s1", 7, Plug.Test.conn(:post, "/"), & &1)
      ctx = %{instance: @server, server: @server_module, session_id: "s1", request_id: 7}

      {duration_us, result} =
        :timer.tc(fn ->
          Invoke.run(
            ctx,
            fn ->
              #
              # A message every 40 ms, for much longer than the 300 ms deadline.
              #
              for _ <- 1..50 do
                PostStream.route(@server, "s1", 7, %{"method" => "ping"})
                Process.sleep(40)
              end

              {:ok, :never}
            end,
            stream: stream
          )
        end)

      assert {{:error, %Error{code: -32603, data: %{"reason" => "timeout"}}}, _stream} = result
      assert duration_us < 1_500_000
      PostStream.close(stream)
    end

    test "are ignored by a caller that has no stream" do
      assert {:ok, :done} =
               Invoke.run(%{instance: @server, server: @server_module}, fn ->
                 PostStream.route(@server, "s1", 7, %{"method" => "ping"})
                 #
                 # The callback keeps working after the message it sent.
                 #
                 Process.sleep(30)
                 {:ok, :done}
               end)

      # The message for a request with no stream was dropped: no stream carries it.
      #
      refute_received {:oz_mcp_stream, _, _}
    end

    @tag :capture_log
    test "a crash of the runner gives the stream back" do
      {:ok, stream} = Utils.begin_stream(@server, "s1", 7, Plug.Test.conn(:post, "/"), & &1)
      ctx = %{instance: @server, server: @server_module, session_id: "s1", request_id: 7}

      {{:error, %Error{code: -32603}}, stream} =
        Invoke.run(
          ctx,
          fn ->
            PostStream.route(@server, "s1", 7, %{"method" => "ping"})
            raise "boom"
          end,
          stream: stream,
          timeout: 30_000
        )

      assert {{:streamed, conn}, _stream} = PostStream.answer(%{"id" => 7}, stream)
      assert conn.resp_body =~ ~s("method":"ping")
      assert conn.resp_body =~ ~s("id":7)
      refute conn.resp_body =~ "boom"
    end
  end

  describe "keep_alive of the wait" do
    setup do
      start_runtime(%{sse_heartbeat_ms: 20})
      :ok
    end

    test "an idle wait with keep_alive: true upgrades the response and writes heartbeats" do
      {:ok, stream} = Utils.begin_stream(@server, "s1", 7, Plug.Test.conn(:post, "/"), & &1)
      ctx = %{instance: @server, server: @server_module, session_id: "s1", request_id: 7}

      {{:ok, :done}, stream} =
        Invoke.run(
          ctx,
          fn ->
            #
            # The callback runs longer than the idle heartbeat interval.
            #
            Process.sleep(100)
            {:ok, :done}
          end,
          keep_alive: true,
          stream: stream
        )

      assert {{:streamed, conn}, _stream} = PostStream.answer(%{"id" => 7}, stream)

      # The first idle heartbeat upgraded the plain response to a stream:
      # the priming event came first, then the comments.
      #
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert conn.resp_body =~ ~r/^id: \S+:0\ndata: \n\n/m
      assert conn.resp_body |> String.split(": heartbeat\n\n") |> length() >= 2

      # A comment is no event: only the response carries a message.
      #
      assert conn.resp_body |> String.split("\n\n", trim: true) |> List.last() =~
               ~s("id":7)
    end

    test "an idle wait without keep_alive leaves the response plain" do
      {:ok, stream} = Utils.begin_stream(@server, "s1", 7, Plug.Test.conn(:post, "/"), & &1)
      ctx = %{instance: @server, server: @server_module, session_id: "s1", request_id: 7}

      {{:ok, :done}, stream} =
        Invoke.run(
          ctx,
          fn ->
            #
            # The callback runs longer than the idle heartbeat interval.
            #
            Process.sleep(100)
            {:ok, :done}
          end,
          stream: stream
        )

      assert {:not_streamed, _stream} = PostStream.answer(%{"id" => 7}, stream)
    end
  end

  describe "cancellation" do
    setup do
      start_runtime(%{request_cancel_grace_ms: 300})
      :ok
    end

    test "stops a running request and answers -32800" do
      {task, runner} = start_blocking(ctx("s1", 1))

      assert Sessions.cancel(@server, "s1", 1, "user aborted") == :ok

      assert {{:error, %Error{code: -32800, message: "request cancelled", data: nil}}, mailbox} =
               Task.await(task, 30_000)

      assert mailbox == []
      wait_until(fn -> not Process.alive?(runner) end)
    end

    test "a cancel that arrives before the callback starts is not lost" do
      task =
        Task.async(fn ->
          ctx = ctx("s1", 1)
          assert :ok = register(ctx)

          # The cancel is on its way before the callback process exists:
          # the session knows the owner from the registration.
          #
          assert :ok = Sessions.cancel(@server, "s1", 1, "early")

          Invoke.run(ctx, fn ->
            receive do
              :never -> {:ok, :never}
            end
          end)
          |> then(fn result ->
            free(ctx)
            result
          end)
        end)

      assert {:error, %Error{code: -32800}} = Task.await(task, 30_000)
    end

    test "frees the request id once the request ended" do
      {task, _runner} = start_blocking(ctx("s1", 1))
      Sessions.cancel(@server, "s1", 1, nil)
      assert {{:error, %Error{code: -32800}}, _} = Task.await(task, 30_000)

      wait_until(fn -> inflight() == [] end)

      assert Invoke.run(ctx("s1", 1), fn -> {:ok, :again} end) == {:ok, :again}
    end

    test "accepts a missing reason" do
      {task, _runner} = start_blocking(ctx("s1", 1))
      Sessions.cancel(@server, "s1", 1, nil)

      assert {{:error, %Error{code: -32800}}, _} = Task.await(task, 30_000)
    end

    test "is a no-op after the request completed" do
      assert Invoke.run(ctx("s1", 1), fn -> {:ok, :done} end) == {:ok, :done}
      assert Sessions.cancel(@server, "s1", 1, "late") == :ok
    end

    test "is a no-op for an unknown request id" do
      assert Sessions.cancel(@server, "s1", 999, "nobody") == :ok
    end

    test "is a no-op when the instance does not run" do
      assert {:error, :unavailable} = Sessions.cancel(@inline_server, "s1", 1, nil)
    end

    test "ignores a request of another session" do
      {task, runner} = start_blocking(ctx("s1", 1))

      runner_ref = Process.monitor(runner)
      assert Sessions.cancel(@server, "s2", 1, "not yours") == :ok

      # The cancel is a no-op for this runner: its DOWN does not arrive.
      #
      refute_receive {:DOWN, ^runner_ref, :process, ^runner, _}, 50

      send(runner, :finish)
      assert {{:ok, :finished}, _} = Task.await(task, 30_000)
    end

    test "ignores a request of another instance" do
      {task, runner} = start_blocking(ctx("s1", 1))

      runner_ref = Process.monitor(runner)
      assert {:error, :unavailable} = Sessions.cancel(@inline_server, "s1", 1, "not yours")

      # The cancel went to another instance: the DOWN of the runner does not arrive.
      #
      refute_receive {:DOWN, ^runner_ref, :process, ^runner, _}, 50

      send(runner, :finish)
      assert {{:ok, :finished}, _} = Task.await(task, 30_000)
    end

    test "compares the request id strictly: \"1\" does not cancel 1" do
      {task, runner} = start_blocking(ctx("s1", 1))

      runner_ref = Process.monitor(runner)
      Sessions.cancel(@server, "s1", "1", nil)

      # The id does not match: the DOWN of the runner does not arrive.
      #
      refute_receive {:DOWN, ^runner_ref, :process, ^runner, _}, 50

      Sessions.cancel(@server, "s1", 1, nil)
      assert {{:error, %Error{code: -32800}}, _} = Task.await(task, 30_000)
    end

    test "compares the request id strictly: 7 does not cancel \"7\"" do
      {task, runner} = start_blocking(ctx("s1", "7"))

      runner_ref = Process.monitor(runner)
      Sessions.cancel(@server, "s1", 7, nil)

      # The id does not match: the DOWN of the runner does not arrive.
      #
      refute_receive {:DOWN, ^runner_ref, :process, ^runner, _}, 50

      Sessions.cancel(@server, "s1", "7", nil)
      assert {{:error, %Error{code: -32800}}, _} = Task.await(task, 30_000)
    end

    test "cancels only the requested one of several running requests" do
      {task1, runner1} = start_blocking(ctx("s1", 1))
      {task2, runner2} = start_blocking(ctx("s1", 2))

      Sessions.cancel(@server, "s1", 2, nil)

      assert {{:error, %Error{code: -32800}}, _} = Task.await(task2, 30_000)
      wait_until(fn -> not Process.alive?(runner2) end)
      assert Process.alive?(runner1)

      send(runner1, :finish)
      assert {{:ok, :finished}, _} = Task.await(task1, 30_000)
    end

    test "works with a %OzMcp.Context{} as ctx" do
      context = %{
        Context.new(@server, :http_streamable, :rpc)
        | session_id: "s1",
          rpc_id: 5
      }

      {task, _runner} = start_blocking(context)
      Sessions.cancel(@server, "s1", 5, nil)

      assert {{:error, %Error{code: -32800}}, _} = Task.await(task, 30_000)
    end

    test "a request without an id is not registered in its session" do
      {task, runner} = start_blocking(ctx("s1", nil))

      assert inflight() == []

      send(runner, :finish)
      assert {{:ok, :finished}, _} = Task.await(task, 30_000)
    end

    test "a request without a session is not registered" do
      {task, runner} = start_blocking(%{instance: @server, server: @server_module, request_id: 1})

      assert inflight() == []

      send(runner, :finish)
      assert {{:ok, :finished}, _} = Task.await(task, 30_000)
    end

    test "a callback that traps exits cleans up in the grace period and its result wins" do
      parent = self()

      {task, _runner} =
        start_blocking(ctx("s1", 1), fn ->
          Process.flag(:trap_exit, true)
          send(parent, {:started, self()})

          try do
            receive do
              {:EXIT, _from, {:shutdown, {:cancelled, reason}}} ->
                send(parent, {:got_signal, reason})
                {:ok, :cleaned}
            end
          after
            send(parent, :cleanup_done)
          end
        end)

      Sessions.cancel(@server, "s1", 1, "user aborted")

      assert {{:ok, :cleaned}, mailbox} = Task.await(task, 30_000)
      assert mailbox == []
      assert_received {:got_signal, "user aborted"}
      assert_received :cleanup_done
    end

    test "a callback that does not trap exits ends at once, without waiting for the grace period" do
      {task, runner} = start_blocking(ctx("s1", 1))

      {duration_us, _} = :timer.tc(fn -> Sessions.cancel(@server, "s1", 1, nil) end)
      assert duration_us < 100_000

      {duration_us, result} = :timer.tc(fn -> Task.await(task, 30_000) end)
      assert {{:error, %Error{code: -32800}}, _} = result

      # No grace wait: the exit signal killed the callback right away.
      #
      assert duration_us < 250_000
      wait_until(fn -> not Process.alive?(runner) end)
    end

    test "a callback that ignores the signal is killed when the grace period elapses" do
      {task, runner} = start_blocking(ctx("s1", 1), ignoring_fun(self()))

      {duration_us, result} =
        :timer.tc(fn ->
          Sessions.cancel(@server, "s1", 1, nil)
          Task.await(task, 30_000)
        end)

      assert {{:error, %Error{code: -32800}}, _} = result
      assert duration_us >= 250_000
      assert duration_us < 3_000_000
      wait_until(fn -> not Process.alive?(runner) end)
    end

    test "a cancel that races with the completion: the result wins, never both" do
      parent = self()
      first = ctx("s1", 1)
      next = ctx("s1", 2)

      task =
        Task.async(fn ->
          register(first)

          result =
            Invoke.run(first, fn ->
              send(parent, {:started, self()})

              receive do
                :finish ->
                  Sessions.cancel(@server, "s1", 1, "race")
                  {:ok, :finished}
              end
            end)

          free(first)

          # `Sessions.cancel/4` is a cast: the session sends the signal to
          # this process when it handles the cast, so it can arrive before
          # the result (the wait flushes it) or after the wait ended. This
          # call returns after the session handled every cast sent before
          # it: the signal is now in the mailbox or was never sent.
          #
          Utils.sync_server(@server, "s1")

          # Whatever the order was, the next request of the caller drops
          # a stale cancel (`Invoke.flush_stale/1`): nothing is left.
          #
          register(next)
          assert {:ok, :next} = Invoke.run(next, fn -> {:ok, :next} end)
          free(next)

          {:messages, mailbox} = Process.info(self(), :messages)
          {result, mailbox}
        end)

      assert_receive {:started, runner}, 5_000
      send(runner, :finish)

      assert {{:ok, :finished}, mailbox} = Task.await(task, 30_000)
      assert mailbox == []
    end

    test "a long cancel reason is bounded and escaped in the log and in the signal" do
      parent = self()

      {task, _runner} =
        start_blocking(ctx("s1", 1), fn ->
          Process.flag(:trap_exit, true)
          send(parent, {:started, self()})

          receive do
            {:EXIT, _from, {:shutdown, {:cancelled, reason}}} ->
              send(parent, {:signal_reason, reason})
              {:ok, :cleaned}
          end
        end)

      reason = "line one\nINJECTED " <> String.duplicate("é", 5_000)

      log =
        Utils.capture_log(fn ->
          Sessions.cancel(@server, "s1", 1, reason)
          assert {{:ok, :cleaned}, _} = Task.await(task, 30_000)
        end)

      assert_received {:signal_reason, signal_reason}
      assert byte_size(signal_reason) <= 200
      assert String.valid?(signal_reason)
      assert String.starts_with?(signal_reason, "line one\nINJECTED")

      assert log =~ "request cancelled (reason: \"line one\\nINJECTED"
      refute log =~ "\nINJECTED"
      assert byte_size(log) < 1_000
    end

    test "a stale cancel message that arrived after the wait is dropped by the next request" do
      task =
        Task.async(fn ->
          assert {:ok, :first} = Invoke.run(ctx("s1", 1), fn -> {:ok, :first} end)

          # The cancel lost the race against the end of the request: the
          # message reaches the caller after it stopped waiting.
          #
          send(self(), {:oz_mcp_cancel, 999, "late"})
          send(self(), {:oz_mcp_cancel, "999", nil})
          send(self(), :unrelated)

          assert {:ok, :second} = Invoke.run(ctx("s1", 2), fn -> {:ok, :second} end)
          {:messages, mailbox} = Process.info(self(), :messages)
          mailbox
        end)

      # Only the stale cancel messages are dropped.
      #
      assert Task.await(task, 30_000) == [:unrelated]
    end

    test "a non-binary reason is dropped" do
      {task, _runner} = start_blocking(ctx("s1", 1))
      Sessions.cancel(@server, "s1", 1, %{"not" => "text"})
      assert {{:error, %Error{code: -32800}}, _} = Task.await(task, 30_000)
    end

    test "the same request id is accepted in two different sessions" do
      {task1, runner1} = start_blocking(ctx("s1", 1))
      {task2, runner2} = start_blocking(ctx("s2", 1))

      send(runner1, :finish)
      send(runner2, :finish)

      assert {{:ok, :finished}, _} = Task.await(task1, 30_000)
      assert {{:ok, :finished}, _} = Task.await(task2, 30_000)
    end

    test "a finished request id can be reused at once" do
      for _ <- 1..100 do
        assert Invoke.run(ctx("s1", 1), fn -> {:ok, :done} end) == {:ok, :done}
      end
    end

    @tag :capture_log
    test "a crashing request frees its id" do
      task =
        Task.async(fn ->
          ctx = ctx("s1", 1)
          register(ctx)

          assert {:error, %Error{code: -32603}} = Invoke.run(ctx, fn -> raise "boom" end)

          # No free/2: the owner ends here, the session frees the id at
          # the monitor of the owner.
          #
        end)

      Task.await(task, 30_000)
      wait_until(fn -> inflight() == [] end)
      assert Invoke.run(ctx("s1", 1), fn -> {:ok, :done} end) == {:ok, :done}
    end
  end

  describe "death of the caller" do
    setup do
      start_runtime(%{request_cancel_grace_ms: 300})
      :ok
    end

    test "the callback is stopped and its request id is freed" do
      {caller, runner} = start_caller(ctx("s1", 1))

      Process.exit(caller, :kill)

      wait_until(fn -> not Process.alive?(runner) end)
      wait_until(fn -> inflight() == [] end)
      assert Invoke.run(ctx("s1", 1), fn -> {:ok, :again} end) == {:ok, :again}
    end

    # A request that is not registered in a session (no session id, no
    # request id) has no stop from the session: only the deadline of its
    # caller stops it. The callback here ends by itself.
    #
    test "a request that is not registered runs until it ends itself" do
      parent = self()

      caller =
        spawn(fn ->
          Invoke.run(%{instance: @server, server: @server_module}, fn ->
            send(parent, {:started, self()})
            #
            # The callback simulates work of 100 ms: it ends by itself.
            #
            Process.sleep(100)
            {:ok, :done}
          end)
        end)

      assert_receive {:started, runner}, 5_000
      Process.exit(caller, :kill)

      # The kill of the caller stops nothing: the DOWN of the runner does
      # not arrive while the callback runs.
      #
      runner_ref = Process.monitor(runner)
      refute_receive {:DOWN, ^runner_ref, :process, ^runner, _}, 20
      wait_until(fn -> not Process.alive?(runner) end)
    end

    test "a callback that traps exits gets the grace period to clean up" do
      parent = self()

      {caller, runner} =
        start_caller(ctx("s1", 1), fn ->
          Process.flag(:trap_exit, true)
          send(parent, {:started, self()})

          receive do
            {:EXIT, _from, :shutdown} -> send(parent, :cleanup_done)
          end

          {:ok, :cleaned}
        end)

      Process.exit(caller, :kill)

      assert_receive :cleanup_done, 5_000
      wait_until(fn -> not Process.alive?(runner) end)
    end

    test "a callback that ignores the signal is killed when the grace period elapses" do
      {caller, runner} = start_caller(ctx("s1", 1), ignoring_fun(self()))

      Process.exit(caller, :kill)

      # The grace period keeps the runner alive: the DOWN does not arrive
      # at once and it arrives after the grace.
      #
      runner_ref = Process.monitor(runner)
      refute_receive {:DOWN, ^runner_ref, :process, ^runner, _}, 100
      wait_until(fn -> not Process.alive?(runner) end)
    end

    test "a callback that finishes normally leaves no watcher behind" do
      before_count = length(Process.list())

      for id <- 1..20, do: assert({:ok, :ok} = Invoke.run(ctx("s1", id), fn -> {:ok, :ok} end))

      wait_until(fn -> length(Process.list()) <= before_count + 2 end)
    end

    test "a finished request is not affected by the later death of its caller" do
      parent = self()

      caller =
        spawn(fn ->
          send(parent, {:result, Invoke.run(ctx("s1", 1), fn -> {:ok, :done} end)})

          receive do
            :never -> :ok
          end
        end)

      assert_receive {:result, {:ok, :done}}, 5_000
      Process.exit(caller, :kill)
      assert Invoke.run(ctx("s1", 1), fn -> {:ok, :again} end) == {:ok, :again}
    end
  end

  describe "the end of the session" do
    setup do
      start_runtime(%{request_cancel_grace_ms: 300})
      :ok
    end

    test "cancels every running request of the session and none of another" do
      {task1, _} = start_blocking(ctx("s1", 1))
      {task2, _} = start_blocking(ctx("s1", 2))
      {task3, runner3} = start_blocking(ctx("s2", 1))

      assert :ok = Sessions.terminate(@server, "s1")

      assert {{:error, %Error{code: -32800, message: "request cancelled"}}, _} =
               Task.await(task1, 30_000)

      assert {{:error, %Error{code: -32800}}, _} = Task.await(task2, 30_000)

      runner3_ref = Process.monitor(runner3)
      refute_receive {:DOWN, ^runner3_ref, :process, ^runner3, _}, 50
      send(runner3, :finish)
      assert {{:ok, :finished}, _} = Task.await(task3, 30_000)
    end

    test "answers -32000 to a request that asks for the error of the end" do
      task =
        Task.async(fn ->
          ctx = ctx("s1", 1)
          assert :ok = register(ctx)

          Invoke.run(ctx, fn -> Process.sleep(:infinity) end, session_end_error: true)
        end)

      wait_until(fn -> requests("s1") == [1] end)
      assert :ok = Sessions.terminate(@server, "s1")

      assert {:error, %Error{code: -32000, message: "session terminated"}} =
               Task.await(task, 30_000)
    end

    test "a session without a running request ends normally" do
      assert :ok = Sessions.terminate(@server, "s1")
      assert {:error, :no_session} = Sessions.terminate(@server, "s1")
    end
  end

  describe "cancellation and deadline together" do
    setup do
      start_runtime(%{request_timeout_ms: 100, request_cancel_grace_ms: 400})
      :ok
    end

    @tag :capture_log
    test "a cancel that arrives while the deadline stops the callback is ignored" do
      {task, _runner} = start_blocking(ctx("s1", 1), ignoring_fun(self()))

      # The deadline (100 ms) elapsed: the callback is in its grace period.
      #
      Process.sleep(200)
      assert Sessions.cancel(@server, "s1", 1, "late") == :ok

      assert {{:error, %Error{code: -32603, data: %{"reason" => "timeout"}}}, mailbox} =
               Task.await(task, 30_000)

      assert mailbox == []
    end

    @tag :capture_log
    test "a callback that finishes in the grace period of the deadline wins" do
      parent = self()

      {task, _runner} =
        start_blocking(ctx("s1", 1), fn ->
          Process.flag(:trap_exit, true)
          send(parent, {:started, self()})

          receive do
            {:EXIT, _from, :shutdown} -> {:ok, :late}
          end
        end)

      assert {{:ok, :late}, _} = Task.await(task, 30_000)
    end

    @tag :capture_log
    test "a cancel before the deadline wins over the timeout" do
      {task, _runner} = start_blocking(ctx("s1", 1))

      Sessions.cancel(@server, "s1", 1, nil)

      assert {{:error, %Error{code: -32800}}, _} = Task.await(task, 30_000)
    end
  end

  describe "start/2 (detached)" do
    setup do
      start_runtime(%{})
      %{supervisor: OzMcp.Instance.via(@server, :calls)}
    end

    test "runs the callback and hands the normalized outcome to :on_exit", %{supervisor: sup} do
      parent = self()

      assert {:ok, pid} =
               Invoke.start(
                 fn ->
                   {:ok,
                    %CallToolResult{}
                    |> CallToolResult.content([%TextContent{} |> TextContent.text("hi")])}
                 end,
                 supervisor: sup,
                 on_exit: fn result -> send(parent, {:outcome, self(), result}) end
               )

      assert_receive {:outcome, ^pid, {:ok, %{content: [%{type: "text", text: "hi"}]}}}
    end

    @tag :capture_log
    test "a crash is guarded and reported through :on_exit", %{supervisor: sup} do
      parent = self()

      {:ok, _pid} =
        Invoke.start(fn -> raise "boom" end,
          supervisor: sup,
          on_exit: fn result -> send(parent, {:outcome, result}) end
        )

      assert_receive {:outcome, {:error, %Error{code: -32603, message: "internal error"}}}
    end

    test "runs under the given supervisor", %{supervisor: sup} do
      parent = self()

      {:ok, pid} =
        Invoke.start(fn -> {:ok, wait_for_finish(parent)} end, supervisor: sup)

      assert pid in Task.Supervisor.children(sup)
      assert_receive {:waiting, ^pid}
      send(pid, :finish)
    end

    test "is never registered as in-flight and cannot be cancelled", %{supervisor: sup} do
      parent = self()

      {:ok, pid} =
        Invoke.start(fn -> {:ok, wait_for_finish(parent)} end,
          supervisor: sup,
          on_exit: fn result -> send(parent, {:outcome, result}) end
        )

      assert_receive {:waiting, ^pid}
      assert inflight() == []

      runner_ref = Process.monitor(pid)
      assert Sessions.cancel(@server, "s1", 1, nil) == :ok

      # The cancel is a no-op while the callback runs: the DOWN does not arrive.
      #
      refute_receive {:DOWN, ^runner_ref, :process, ^pid, _}, 50

      send(pid, :finish)
      assert_receive {:outcome, {:ok, :finished}}
    end

    test "requires a :supervisor" do
      assert_raise KeyError, fn -> Invoke.start(fn -> {:ok, 1} end, []) end
    end

    @tag :capture_log
    test "with method tools/call, a map with no content is an internal error", %{supervisor: sup} do
      parent = self()

      assert {:ok, _pid} =
               Invoke.start(fn -> {:ok, %{}} end,
                 supervisor: sup,
                 method: "tools/call",
                 on_exit: fn result -> send(parent, {:outcome, result}) end
               )

      assert_receive {:outcome, {:error, %Error{code: -32603, message: "internal error"}}}
    end

    @tag :capture_log
    test "with method tools/call, a string result is an internal error", %{supervisor: sup} do
      parent = self()

      assert {:ok, _pid} =
               Invoke.start(fn -> {:ok, "text"} end,
                 supervisor: sup,
                 method: "tools/call",
                 on_exit: fn result -> send(parent, {:outcome, result}) end
               )

      assert_receive {:outcome, {:error, %Error{code: -32603, message: "internal error"}}}
    end

    test "with method tools/call, a CallToolResult struct and a map with content pass", %{
      supervisor: sup
    } do
      parent = self()

      assert {:ok, _pid} =
               Invoke.start(
                 fn ->
                   {:ok,
                    %CallToolResult{}
                    |> CallToolResult.content([%TextContent{} |> TextContent.text("hi")])}
                 end,
                 supervisor: sup,
                 method: "tools/call",
                 on_exit: fn result -> send(parent, {:struct_outcome, result}) end
               )

      assert_receive {:struct_outcome, {:ok, %{content: [%{type: "text", text: "hi"}]}}}

      assert {:ok, _pid} =
               Invoke.start(fn -> {:ok, %{"content" => []}} end,
                 supervisor: sup,
                 method: "tools/call",
                 on_exit: fn result -> send(parent, {:map_outcome, result}) end
               )

      assert_receive {:map_outcome, {:ok, %{content: []}}}
    end

    test "with no method, the result is not checked", %{supervisor: sup} do
      parent = self()

      assert {:ok, _pid} =
               Invoke.start(fn -> {:ok, %{}} end,
                 supervisor: sup,
                 on_exit: fn result -> send(parent, {:outcome, result}) end
               )

      assert_receive {:outcome, {:ok, %{}}}
    end

    test "the :check option validates the built result in the guard", %{supervisor: sup} do
      parent = self()

      assert {:ok, _pid} =
               Invoke.start(fn -> {:ok, %{"content" => []}} end,
                 supervisor: sup,
                 check: fn _result -> :ok end,
                 on_exit: fn result -> send(parent, {:outcome, result}) end
               )

      assert_receive {:outcome, {:ok, %{"content" => []}}}

      assert {:ok, _pid} =
               Invoke.start(fn -> {:ok, %{"content" => []}} end,
                 supervisor: sup,
                 check: fn _result -> {:error, ["bad"]} end,
                 on_exit: fn result -> send(parent, {:checked, result}) end
               )

      assert_receive {:checked, {:error, %{code: -32603, data: ["bad"]}}}
    end

    @tag :capture_log
    test "a check that raises gives the internal error through :on_exit", %{supervisor: sup} do
      parent = self()

      assert {:ok, pid} =
               Invoke.start(fn -> {:ok, %{}} end,
                 supervisor: sup,
                 check: fn _result -> raise "the check exploded" end,
                 on_exit: fn result -> send(parent, {:outcome, result}) end
               )

      assert_receive {:outcome, {:error, %Error{code: -32603, message: "internal error"}}}
      wait_until(fn -> not Process.alive?(pid) end)
    end
  end

  defp start_runtime(opts) do
    Utils.start_instance(@server_module, [name: @server] ++ Map.to_list(opts))

    # The sessions the tests register their requests in.
    #
    {:ok, _} = OzMcp.Session.start(@server, %{session_id: "s1"})
    {:ok, _} = OzMcp.Session.start(@server, %{session_id: "s2"})
    :ok
  end

  defp ctx(session_id, request_id),
    do: %{
      instance: @server,
      server: @server_module,
      session_id: session_id,
      request_id: request_id
    }

  defp request_of(%OzMcp.Context{instance: instance, session_id: sid, rpc_id: id}),
    do: {instance, sid, id}

  defp request_of(%{instance: instance, session_id: sid, request_id: id}),
    do: {instance, sid, id}

  defp request_of(_ctx), do: {nil, nil, nil}

  # The transports register a request in its session before the handler
  # runs and free the id when the answer is out. The tests of Invoke.run
  # do the same around the call, so the session knows the requests.
  #
  defp register(ctx) do
    {instance, session_id, request_id} = request_of(ctx)

    if is_binary(session_id) and (is_binary(request_id) or is_integer(request_id)) do
      Utils.open_request(instance, session_id, request_id, self())
    end

    :ok
  end

  defp free(ctx) do
    {instance, session_id, request_id} = request_of(ctx)

    if is_binary(session_id) and (is_binary(request_id) or is_integer(request_id)) do
      Session.end_request(instance, session_id, request_id)
    end

    :ok
  end

  # The ids of the requests of a session that are registered right now.
  #
  defp requests(session_id) do
    case Utils.session_data(@server, session_id) do
      nil -> []
      data -> Map.keys(data.requests)
    end
  end

  defp inflight, do: requests("s1")

  # Runs the request in a separate process (it blocks until told to finish,
  # or until it is stopped) and returns {task, runner_pid} once the callback
  # started. The task answers {result, mailbox of the waiting process}, the
  # mailbox proves that no stray cancel message is left behind.
  #
  defp start_blocking(ctx, fun \\ nil, run_opts \\ []) do
    parent = self()

    fun =
      fun ||
        fn ->
          send(parent, {:started, self()})

          receive do
            :finish -> {:ok, :finished}
          end
        end

    task =
      Task.async(fn ->
        register(ctx)
        result = Invoke.run(ctx, fun, run_opts)
        free(ctx)
        {:messages, mailbox} = Process.info(self(), :messages)
        {result, mailbox}
      end)

    assert_receive {:started, runner}, 5_000
    {task, runner}
  end

  # Runs the request in a plain process (not a Task, so that it can be
  # killed like a request process) and returns {caller, runner_pid}.
  #
  defp start_caller(ctx, fun \\ nil) do
    parent = self()

    fun =
      fun ||
        fn ->
          send(parent, {:started, self()})
          Process.sleep(:infinity)
        end

    caller =
      spawn(fn ->
        register(ctx)
        Invoke.run(ctx, fun)
      end)

    assert_receive {:started, runner}, 5_000
    {caller, runner}
  end

  # A callback that traps exits and ignores every signal.
  #
  defp ignoring_fun(parent) do
    fn ->
      Process.flag(:trap_exit, true)
      send(parent, {:started, self()})
      ignore_everything()
    end
  end

  defp ignore_everything do
    receive do
      :never -> :ok
    end

    ignore_everything()
  end

  defp wait_for_finish(parent) do
    send(parent, {:waiting, self()})

    receive do
      :finish -> :finished
    end
  end

  defp wait_until(fun, retries \\ 1_500) do
    if Utils.eventually(fun, retries * 10) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end
end
