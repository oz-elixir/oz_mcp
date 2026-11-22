defmodule OzMcp.Validate.JsonRpcTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
  alias OzMcp.Context
  alias OzMcp.Pipeline.Bind
  alias OzMcp.Validate.JsonRpc
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default

  @server Module.concat(@server_module, __MODULE__)

  @tools_only Servers.ToolsOnly
  @need_rpc_id_methods [
    "ping",
    "initialize",
    "resources/list",
    "resources/templates/list",
    "resources/read",
    #
    # NOTE: resources/subscribe and resources/unsubscribe cannot be listed here:
    # they are rejected by the capabilities check (@server declares
    # subscribe false) before the rpc id check happens.
    # See "validate/1 - params (resources subscribe)" tests.
    # "resources/subscribe",
    # "resources/unsubscribe",
    #
    "tools/list",
    "tools/call"
  ]

  setup do
    Utils.start_instance(@server_module, name: @server)
  end

  defp context(conn, overrides \\ []) do
    mode = Keyword.get(overrides, :mode, :rpc)

    OzMcp.Context.new(conn.private.server, :http_streamable, mode)
    |> OzMcp.Context.put_http_conn(conn)
    |> Map.put(:session_id, Keyword.get(overrides, :session_id))
    |> Map.put(:rpc_id, Keyword.get(overrides, :rpc_id))
    |> Map.put(:rpc_method, Keyword.get(overrides, :rpc_method))
    |> Map.put(:rpc_params, Keyword.get(overrides, :rpc_params))
  end

  defp build_base_conn(body) do
    body = Map.put(body, "jsonrpc", "2.0")

    conn(:post, "/", :json.encode(body) |> IO.iodata_to_binary())
    |> put_private(:server, @server)
    |> Map.put(:body_params, body)
  end

  defp build_conn(body) do
    build_base_conn(body)
    |> put_req_header("accept", "application/json, text/event-stream")
  end

  defp build_conn_with_server(server, body) do
    build_conn(body)
    |> put_private(:server, server)
  end

  # The tests of the bind of the entity run the two steps, as the
  # pipelines do: validate/1 checks the shape of the params, Bind.run/1
  # finds the entity and validates the arguments.
  #
  defp validate_and_bind(context) do
    case JsonRpc.validate(context) do
      {:cont, context} -> plain(Bind.run(context))
      {:halt, context} -> context
    end
  end

  defp plain({:cont, context}), do: context
  defp plain({:halt, context}), do: context

  # -------------------------------------------------------------------
  # validate/1
  # -------------------------------------------------------------------

  describe "validate/1" do
    test "extracts id, method, params from body" do
      body = %{"id" => 1, "method" => "ping", "params" => %{"key" => "val"}}
      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      assert ctx.rpc_id == 1
      assert ctx.rpc_method == "ping"
      assert ctx.rpc_params == %{"key" => "val"}
    end

    test "sets nil for missing fields" do
      body = %{"method" => "ping"}
      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      assert ctx.rpc_id == nil
      assert ctx.rpc_params == nil
    end

    test "returns with rpc error when method is missing" do
      ctx =
        validate_and_bind(context(build_conn_with_server(@server, %{"id" => 1})))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_request
    end

    test "returns with rpc error when rpc 'id' is required and it is missing" do
      Enum.each(@need_rpc_id_methods, fn method ->
        #
        # Empty params keep methods that require params (resources/read,
        # tools/call) past the presence check so the id check is reached.
        #
        ctx =
          validate_and_bind(
            context(build_conn_with_server(@server, %{"method" => method, "params" => %{}}))
          )

        refute is_nil(ctx.error)
        assert ctx.error.code == :rpc_missing_id
      end)
    end

    test "does not require rpc id for notifications/initialized" do
      ctx =
        plain(
          JsonRpc.validate(
            context(
              build_conn_with_server(@server, %{
                "method" => "notifications/initialized"
              })
            )
          )
        )

      assert is_nil(ctx.error)
    end

    test "passes when rpc id and method are present" do
      ctx =
        validate_and_bind(
          context(build_conn_with_server(@server, %{"id" => 1, "method" => "ping"}))
        )

      assert is_nil(ctx.error)
      assert ctx.rpc_method == "ping"
      assert ctx.rpc_id == 1
    end
  end

  # -------------------------------------------------------------------
  # validate/1 - envelope
  # -------------------------------------------------------------------

  # These tests need exact control over the wire body (no injected
  # "jsonrpc" member), hence the dedicated conn builder.
  #
  defp raw_conn(server, body) do
    conn(:post, "/", :json.encode(body) |> IO.iodata_to_binary())
    |> put_private(:server, server)
    |> put_req_header("accept", "application/json, text/event-stream")
    |> Map.put(:body_params, body)
  end

  describe "validate/1 - envelope (jsonrpc member)" do
    @valid_body %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}

    test "passes when jsonrpc is exactly '2.0'" do
      ctx = plain(JsonRpc.validate(context(raw_conn(@server, @valid_body))))

      assert is_nil(ctx.error)
    end

    test "returns with rpc error when jsonrpc is missing" do
      body = Map.delete(@valid_body, "jsonrpc")
      ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_request
    end

    test "returns with rpc error when jsonrpc is not '2.0'" do
      Enum.each(["1.0", "2.1", "3.0", "", 2.0, 2, true, nil, %{}, []], fn jsonrpc ->
        body = Map.put(@valid_body, "jsonrpc", jsonrpc)
        ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

        refute is_nil(ctx.error), "expected an error for jsonrpc: #{inspect(jsonrpc)}"
        assert ctx.error.code == :rpc_invalid_request
      end)
    end
  end

  describe "validate/1 - response of the client" do
    defp validate_response(body), do: plain(JsonRpc.validate(context(raw_conn(@server, body))))

    test "accepts a result and keeps it in rpc_response" do
      body = %{"jsonrpc" => "2.0", "id" => "abc", "result" => %{"roots" => []}}
      ctx = validate_response(body)

      assert is_nil(ctx.error)
      assert ctx.rpc_id == "abc"
      assert ctx.rpc_method == nil
      assert ctx.rpc_response == {:ok, %{"roots" => []}}
    end

    test "accepts an empty result and an integer id" do
      ctx = validate_response(%{"jsonrpc" => "2.0", "id" => 3, "result" => %{}})

      assert is_nil(ctx.error)
      assert ctx.rpc_id == 3
      assert ctx.rpc_response == {:ok, %{}}
    end

    test "accepts an error object and keeps it in rpc_response" do
      error = %{"code" => -32601, "message" => "nope", "data" => %{"a" => 1}}
      ctx = validate_response(%{"jsonrpc" => "2.0", "id" => "abc", "error" => error})

      assert is_nil(ctx.error)
      assert ctx.rpc_response == {:error, error}
    end

    test "accepts an error with no id and keeps an orphan error in rpc_response" do
      error = %{"code" => -32601, "message" => "nope"}
      ctx = validate_response(%{"jsonrpc" => "2.0", "error" => error})

      assert is_nil(ctx.error)
      assert ctx.rpc_id == nil
      assert ctx.rpc_kind == :response
      refute Context.request?(ctx)
      assert ctx.rpc_response == {:orphan_error, error}
    end

    test "accepts an error with an id of null as an orphan error" do
      error = %{"code" => -32001, "message" => "invalid session", "data" => %{"a" => 1}}
      ctx = validate_response(%{"jsonrpc" => "2.0", "id" => nil, "error" => error})

      assert is_nil(ctx.error)
      assert ctx.rpc_id == nil
      assert ctx.rpc_response == {:orphan_error, error}
    end

    test "an orphan error that is not valid is an invalid request" do
      for error <- ["x", nil, [], %{"code" => "1", "message" => "x"}, %{"code" => 1}] do
        body = %{"jsonrpc" => "2.0", "error" => error}
        assert validate_response(body).error.code == :rpc_invalid_request
      end
    end

    test "does not need the server to declare any capability" do
      ctx = validate_response(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})

      assert is_nil(ctx.error)
    end

    test "is invalid without jsonrpc 2.0" do
      for jsonrpc <- [nil, "1.0", 2, nil] do
        body = %{"jsonrpc" => jsonrpc, "id" => 1, "result" => %{}}
        ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

        assert ctx.error.code == :rpc_invalid_request
      end
    end

    test "is invalid without an id of type string or integer" do
      for id <- [nil, 1.5, true, %{}, []] do
        body = %{"jsonrpc" => "2.0", "id" => id, "result" => %{}}
        assert validate_response(body).error.code == :rpc_invalid_request
      end

      body = %{"jsonrpc" => "2.0", "result" => %{}}
      assert validate_response(body).error.code == :rpc_invalid_request
    end

    test "is invalid with both a result and an error" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{},
        "error" => %{"code" => 1, "message" => "x"}
      }

      assert validate_response(body).error.code == :rpc_invalid_request
    end

    test "is invalid when the result is not an object" do
      for result <- [nil, 1, "x", true, []] do
        body = %{"jsonrpc" => "2.0", "id" => 1, "result" => result}
        assert validate_response(body).error.code == :rpc_invalid_request
      end
    end

    test "is invalid when the error is not an object with an integer code and a message" do
      for error <- [
            nil,
            "x",
            [],
            %{},
            %{"code" => "1", "message" => "x"},
            %{"code" => 1},
            %{"code" => 1, "message" => 2}
          ] do
        body = %{"jsonrpc" => "2.0", "id" => 1, "error" => error}
        assert validate_response(body).error.code == :rpc_invalid_request
      end
    end

    test "a message that has a method is a request, whatever else it carries" do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "result" => %{}}
      ctx = validate_response(body)

      assert is_nil(ctx.error)
      assert ctx.rpc_response == nil
      assert ctx.rpc_method == "ping"
    end
  end

  describe "validate/1 - rpc_kind" do
    test "a request with a valid id gets :request" do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}
      ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

      assert ctx.rpc_kind == :request
      assert Context.request?(ctx)
    end

    test "a request that fails the envelope check still gets :request" do
      body = %{"jsonrpc" => "1.0", "id" => 1, "method" => "ping"}
      ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_request
      assert ctx.rpc_kind == :request
      assert Context.request?(ctx)
    end

    test "a notification gets :notification" do
      body = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

      assert is_nil(ctx.error)
      assert ctx.rpc_kind == :notification
      refute Context.request?(ctx)
    end

    test "a client response gets :response" do
      body = %{"jsonrpc" => "2.0", "id" => "abc", "result" => %{}}
      ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

      assert is_nil(ctx.error)
      assert ctx.rpc_kind == :response
      refute Context.request?(ctx)
    end

    test "a message with an invalid id gets :invalid" do
      body = %{"jsonrpc" => "2.0", "id" => nil, "method" => "ping"}
      ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_request
      assert ctx.rpc_kind == :invalid
      refute Context.request?(ctx)
    end

    test "an empty map body gets :invalid" do
      ctx = plain(JsonRpc.validate(context(raw_conn(@server, %{}))))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_request
      assert ctx.rpc_kind == :invalid
      refute Context.request?(ctx)
    end
  end

  describe "validate/1 - envelope (method member)" do
    @valid_body %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}

    # A notifications/* method needs a body with no id: with an id the
    # check of the envelope refuses the message with rpc_method_not_found
    # (see the describe about a notification method with an id).
    #
    test "passes for a non-empty string method" do
      Enum.each(["ping", "tools/call", "unknown"], fn method ->
        body = Map.put(@valid_body, "method", method)
        ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

        refute match?(%{error: %{code: :rpc_invalid_request}}, ctx),
               "expected no envelope error for method: #{method}"
      end)
    end

    test "returns with rpc error when method is missing" do
      body = Map.delete(@valid_body, "method")
      ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_request
    end

    test "returns with rpc error when method is empty or not a string" do
      Enum.each(["", 42, 1.5, true, nil, %{}, [], %{"a" => 1}], fn method ->
        body = Map.put(@valid_body, "method", method)
        ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

        refute is_nil(ctx.error), "expected an error for method: #{inspect(method)}"
        assert ctx.error.code == :rpc_invalid_request
      end)
    end
  end

  describe "validate/1 - envelope (notification method with an id)" do
    test "gets rpc_method_not_found for every notifications/* method" do
      Enum.each(
        ["notifications/initialized", "notifications/cancelled", "notifications/x"],
        fn method ->
          body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method}
          ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

          refute is_nil(ctx.error), "expected an error for method: #{method}"
          assert ctx.error.code == :rpc_method_not_found
          assert ctx.rpc_kind == :request
          assert Context.request?(ctx)
        end
      )
    end

    test "runs before the check of the required params" do
      #
      # notifications/cancelled requires params: a bad request with a
      # notification method must never get a different error first.
      #
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "notifications/cancelled"}
      ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

      assert ctx.error.code == :rpc_method_not_found
    end

    test "an id of null keeps the invalid request refusal" do
      #
      # A present id of null is not a string or an integer: the check of
      # the id refuses it before the check of the notification method.
      #
      body = %{"jsonrpc" => "2.0", "id" => nil, "method" => "notifications/initialized"}
      ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

      assert ctx.error.code == :rpc_invalid_request
    end

    test "a notification method with no id still passes the envelope" do
      body = %{"jsonrpc" => "2.0", "method" => "notifications/cancelled"}
      ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

      assert is_nil(ctx.error)
      assert ctx.rpc_kind == :notification
    end
  end

  describe "validate/1 - envelope (id member)" do
    @valid_body %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}

    test "passes when id is absent on a notification" do
      body = %{"jsonrpc" => "2.0", "method" => "notifications/unknown"}
      ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

      refute match?(%{error: %{code: :rpc_invalid_request}}, ctx)
    end

    test "passes when id is a string or an integer" do
      Enum.each(["abc", "", "task-1", 0, -5, 9_999_999], fn id ->
        body = Map.put(@valid_body, "id", id)
        ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

        refute match?(%{error: %{code: :rpc_invalid_request}}, ctx),
               "expected no envelope error for id: #{inspect(id)}"
      end)
    end

    test "returns with rpc error when id is null, boolean, float, array or object" do
      Enum.each([nil, true, false, 1.5, -0.5, [], %{}, %{"a" => 1}, [1, 2]], fn id ->
        body = Map.put(@valid_body, "id", id)
        ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

        refute is_nil(ctx.error), "expected an error for id: #{inspect(id)}"
        assert ctx.error.code == :rpc_invalid_request
      end)
    end
  end

  describe "validate/1 - envelope (params member)" do
    @valid_body %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{}}

    test "passes when params are absent or an object" do
      Enum.each([%{}, %{"any" => "thing"}, %{"nested" => %{"deep" => []}}], fn params ->
        body = Map.put(@valid_body, "params", params)
        ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

        refute match?(%{error: %{code: :rpc_invalid_request}}, ctx),
               "expected no envelope error for params: #{inspect(params)}"
      end)

      body = Map.delete(@valid_body, "params")
      ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

      refute match?(%{error: %{code: :rpc_invalid_request}}, ctx)
    end

    test "returns with rpc error when params are not an object" do
      Enum.each([[], ["a"], "x", 42, 1.5, true], fn params ->
        body = Map.put(@valid_body, "params", params)
        ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

        refute is_nil(ctx.error), "expected an error for params: #{inspect(params)}"
        assert ctx.error.code == :rpc_invalid_request
      end)
    end

    test "treats a params null member as absent" do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => nil}

      ctx = plain(JsonRpc.validate(context(raw_conn(@tools_only, body))))

      assert is_nil(ctx.error)
      assert ctx.rpc_params == nil
    end

    test "params that are not an object never reach the params validation" do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => []}

      ctx = plain(JsonRpc.validate(context(raw_conn(@tools_only, body))))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_request
    end
  end

  describe "validate/1 - envelope (progress token extraction)" do
    test "progress_token is nil when params are not an object" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => ["not", "a", "map"]
      }

      ctx = plain(JsonRpc.validate(context(raw_conn(@tools_only, body))))

      assert ctx.error.code == :rpc_invalid_request
      assert ctx.progress_token == nil
    end

    test "progress_token is nil when _meta is not an object" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "get_date", "_meta" => ["not", "a", "map"]}
      }

      ctx = plain(JsonRpc.validate(context(raw_conn(@tools_only, body))))

      assert ctx.error.code == :rpc_invalid_meta
      assert ctx.progress_token == nil
    end
  end

  describe "validate/1 - envelope" do
    test "runs before any other check for a fully malformed body" do
      body = %{"jsonrpc" => 2, "id" => %{"x" => 1}, "method" => [], "params" => "nope"}
      ctx = plain(JsonRpc.validate(context(raw_conn(@server, body))))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_request
    end
  end

  # -------------------------------------------------------------------
  # validate/1 - progress token
  # -------------------------------------------------------------------

  describe "validate/1 - progress token" do
    test "extracts progressToken from params._meta for tools/call" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "get_date",
          "_meta" => %{"progressToken" => "tok-1"}
        }
      }

      ctx = validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      assert is_nil(ctx.error)
      assert ctx.progress_token == "tok-1"
    end

    test "passes numeric progressToken through unvalidated" do
      body = %{
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => "get_date", "_meta" => %{"progressToken" => 42}}
      }

      ctx = validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      assert is_nil(ctx.error)
      assert ctx.progress_token == 42
    end

    test "progress_token is nil when _meta is missing" do
      body = %{"id" => 3, "method" => "tools/call", "params" => %{"name" => "get_date"}}

      ctx = validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      assert is_nil(ctx.error)
      assert ctx.progress_token == nil
    end

    test "progress_token is nil when params are missing" do
      body = %{"id" => 4, "method" => "ping"}

      ctx = validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      assert is_nil(ctx.error)
      assert ctx.progress_token == nil
    end

    test "progress_token is nil when _meta has no progressToken key" do
      body = %{
        "id" => 5,
        "method" => "tools/call",
        "params" => %{"name" => "get_date", "_meta" => %{"other" => "value"}}
      }

      ctx = validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      assert is_nil(ctx.error)
      assert ctx.progress_token == nil
    end

    test "progress_token survives argument validation (params rewrite)" do
      #
      # tools/call with an inputSchema-validating tool: tools_call/3
      # rebuilds rpc_params; _meta must still yield the token on Context.
      #
      body = %{
        "id" => 6,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "value", "integer_1" => 1},
          "_meta" => %{"progressToken" => "tok-2"}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert is_nil(ctx.error)
      assert ctx.progress_token == "tok-2"
    end
  end

  # -------------------------------------------------------------------
  # validate/1 - _meta and progressToken
  # -------------------------------------------------------------------

  describe "validate/1 - _meta and progressToken" do
    test "a progressToken of null is the same as no progressToken" do
      params = %{"name" => "get_date", "_meta" => %{"progressToken" => nil}}

      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => params}

      ctx = validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      assert is_nil(ctx.error)
      assert ctx.progress_token == nil
    end

    test "a _meta of null is the same as no _meta" do
      params = %{"name" => "get_date", "_meta" => nil}

      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => params}

      ctx = validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      assert is_nil(ctx.error)
      assert ctx.progress_token == nil
      refute Map.has_key?(ctx.rpc_params, "_meta")
    end

    test "a progressToken of a wrong type is refused" do
      for bad <- [1.5, true, [], %{}] do
        params = %{"name" => "get_date", "_meta" => %{"progressToken" => bad}}

        body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => params}

        ctx =
          plain(JsonRpc.validate(context(build_conn_with_server(@tools_only, body))))

        assert ctx.error.code == :rpc_invalid_progress_token,
               "expected a refusal for progressToken #{inspect(bad)}"
      end
    end

    test "a _meta that is not an object is refused" do
      for bad <- ["x", 1, [], true] do
        params = %{"name" => "get_date", "_meta" => bad}

        body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => params}

        ctx =
          plain(JsonRpc.validate(context(build_conn_with_server(@tools_only, body))))

        assert ctx.error.code == :rpc_invalid_meta,
               "expected a refusal for _meta #{inspect(bad)}"
      end
    end

    test "a string token and an integer token pass" do
      for token <- ["abc", 0, -1, 42] do
        params = %{"name" => "get_date", "_meta" => %{"progressToken" => token}}

        body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => params}

        ctx =
          validate_and_bind(context(build_conn_with_server(@tools_only, body)))

        assert is_nil(ctx.error)
        assert ctx.progress_token == token
      end
    end

    test "no _meta and _meta with no progressToken pass" do
      for params <- [%{"name" => "get_date"}, %{"name" => "get_date", "_meta" => %{}}] do
        body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => params}

        ctx =
          validate_and_bind(context(build_conn_with_server(@tools_only, body)))

        assert is_nil(ctx.error)
        assert ctx.progress_token == nil
      end
    end

    test "a notification with a bad _meta is refused" do
      body = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => 1, "reason" => "test", "_meta" => "x"}
      }

      ctx =
        plain(JsonRpc.validate(context(build_conn_with_server(Servers.Default, body))))

      assert ctx.error.code == :rpc_invalid_meta
    end

    test "an earlier error wins over a bad _meta" do
      #
      # The id stage runs before the meta stage: a request with no id
      # gives its own error and the meta stage never runs.
      #
      body = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => "get_date", "_meta" => "x"}
      }

      ctx =
        plain(JsonRpc.validate(context(build_conn_with_server(@tools_only, body))))

      assert ctx.error.code == :rpc_missing_id
    end
  end

  # -------------------------------------------------------------------
  # validate/1 - required params presence
  # -------------------------------------------------------------------

  describe "validate/1 - required params presence" do
    test "returns with rpc error for methods with required params when params are absent" do
      methods = [
        {"tools/call", @tools_only},
        {"prompts/get", Servers.PromptsOnly},
        {"tasks/get", Servers.TasksTest},
        {"tasks/cancel", Servers.TasksTest},
        {"tasks/result", Servers.TasksTest},
        {"resources/read", @server},
        {"resources/subscribe", Servers.ResourcesMultipleSubscribed},
        {"resources/unsubscribe", Servers.ResourcesMultipleSubscribed},
        {"logging/setLevel", Servers.WithLogging}
      ]

      Enum.each(methods, fn {method, server} ->
        body = %{"id" => 1, "method" => method}

        ctx = validate_and_bind(context(build_conn_with_server(server, body)))

        refute is_nil(ctx.error)
        assert ctx.error.code == :rpc_missing_params
      end)
    end

    test "passes for methods with optional params when params are absent" do
      methods = [
        {"tools/list", @tools_only},
        {"prompts/list", Servers.PromptsOnly},
        {"tasks/list", Servers.TasksTest},
        {"resources/list", @server},
        {"resources/templates/list", Servers.WithTemplates}
      ]

      Enum.each(methods, fn {method, server} ->
        body = %{"id" => 1, "method" => method}

        ctx = validate_and_bind(context(build_conn_with_server(server, body)))

        assert is_nil(ctx.error)
      end)
    end

    test "empty params map is not treated as missing" do
      body = %{"id" => 1, "method" => "tools/call", "params" => %{}}

      ctx =
        validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_missing_name_parameter
    end
  end

  # -------------------------------------------------------------------
  # validate/1 - params
  # -------------------------------------------------------------------

  describe "validate/1 - params" do
    test "returns with rpc error when uri is missing for resources/read" do
      body = %{"id" => 1, "method" => "resources/read", "params" => %{}}
      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_missing_uri_parameter
    end

    test "returns with rpc error when uri is nil for resources/read" do
      body = %{"id" => 1, "method" => "resources/read", "params" => %{"uri" => nil}}
      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_missing_uri_parameter
    end

    test "returns with rpc error when uri is not a string for resources/read" do
      body = %{"id" => 1, "method" => "resources/read", "params" => %{"uri" => 123}}
      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_missing_uri_parameter
    end

    test "returns with rpc_resource_not_found error when uri does not match any resource or template" do
      body = %{
        "id" => 1,
        "method" => "resources/read",
        "params" => %{"uri" => "file:///nonexistent.md"}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.WithTemplates, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_resource_not_found
      assert ctx.error.data == %{"uri" => "file:///nonexistent.md"}
    end

    test "binds the kind, the module and the entity when uri matches a resource" do
      body = %{
        "id" => 1,
        "method" => "resources/read",
        "params" => %{"uri" => "file:///marketing.md"}
      }

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.kind == :resource
      assert ctx.bound.module == Support.Entities.Resources.FirstTest
      assert %OzMcp.Structs.Resource{} = ctx.bound.entity
      assert ctx.bound.entity.uri == "file:///marketing.md"
      assert ctx.bound.uri_params == nil
    end

    test "binds the kind, the module, the entity and the uri params when uri matches a template" do
      body = %{
        "id" => 1,
        "method" => "resources/read",
        "params" => %{"uri" => "file://docs/intro.md"}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.WithTemplates, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.kind == :template
      assert ctx.bound.module == Support.Entities.Templates.FirstTest
      assert %OzMcp.Structs.ResourceTemplate{} = ctx.bound.entity
      assert ctx.bound.entity.uriTemplate == "file://docs/{path}"
      assert ctx.bound.uri_params == %{"path" => "intro.md"}
    end

    test "returns with rpc error when name is missing for tools/call" do
      body = %{"method" => "tools/call", "params" => %{}}
      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_missing_id
    end

    test "returns with rpc error when name is nil for tools/call" do
      body = %{"method" => "tools/call", "params" => %{"name" => nil}}
      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_missing_id
    end

    test "returns with rpc error when name is not a string for tools/call" do
      body = %{"id" => 1, "method" => "tools/call", "params" => %{"name" => 123}}
      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_missing_name_parameter
    end

    test "passes when name is present for tools/call" do
      body = %{"id" => 1, "method" => "tools/call", "params" => %{"name" => "get_date"}}
      conn = build_conn_with_server(@tools_only, body)
      ctx = plain(JsonRpc.validate(context(conn)))

      assert is_nil(ctx.error)
    end

    test "passes through for methods without param validation" do
      body = %{"id" => 1, "method" => "ping"}
      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      assert is_nil(ctx.error)
    end

    test "passes through for resources/list with nil params" do
      body = %{"id" => 1, "method" => "resources/list"}
      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      assert is_nil(ctx.error)
    end

    test "passes through for resources/templates/list with nil params" do
      body = %{"id" => 1, "method" => "resources/templates/list"}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.WithTemplates, body)))

      assert is_nil(ctx.error)
    end
  end

  describe "validate/1 - params (completion/complete)" do
    @completion_server Servers.Completions

    defp completion_ctx(ref, argument, context \\ nil) do
      params = %{"ref" => ref, "argument" => argument}
      params = if context, do: Map.put(params, "context", context), else: params

      body = %{"id" => 1, "method" => "completion/complete", "params" => params}
      validate_and_bind(context(build_conn_with_server(@completion_server, body)))
    end

    test "sets completion fields for a prompt reference" do
      ctx =
        completion_ctx(%{"type" => "ref/prompt", "name" => "code_review"}, %{
          "name" => "language",
          "value" => "el"
        })

      assert is_nil(ctx.error)
      assert ctx.bound.module == Support.Entities.Prompts.FirstTest
      assert ctx.completion_ref == "code_review"
      assert ctx.completion_argument == %{"name" => "language", "value" => "el"}
      assert ctx.completion_context == nil
    end

    test "sets completion fields for a resource template reference" do
      ctx =
        completion_ctx(
          %{"type" => "ref/resource", "uri" => "file://docs/{path}"},
          %{"name" => "path", "value" => "in"}
        )

      assert is_nil(ctx.error)
      assert ctx.bound.module == Support.Entities.Templates.FirstTest
      assert ctx.completion_ref == "file://docs/{path}"
    end

    test "stores the context arguments when provided" do
      ctx =
        completion_ctx(
          %{"type" => "ref/prompt", "name" => "code_review"},
          %{"name" => "language", "value" => ""},
          %{"arguments" => %{"focus" => "security"}}
        )

      assert is_nil(ctx.error)
      assert ctx.completion_context == %{"focus" => "security"}
    end

    test "stores an empty map of context arguments" do
      ctx =
        completion_ctx(
          %{"type" => "ref/prompt", "name" => "code_review"},
          %{"name" => "language", "value" => "el"},
          %{"arguments" => %{}}
        )

      assert is_nil(ctx.error)
      assert ctx.completion_context == %{}
    end

    test "a context of null is the same as an absent context" do
      params = %{
        "ref" => %{"type" => "ref/prompt", "name" => "code_review"},
        "argument" => %{"name" => "language", "value" => "el"},
        "context" => nil
      }

      body = %{"id" => 1, "method" => "completion/complete", "params" => params}

      ctx = validate_and_bind(context(build_conn_with_server(@completion_server, body)))

      assert is_nil(ctx.error)
      assert ctx.completion_context == nil
    end

    test "context arguments of null are the same as no context arguments" do
      ctx =
        completion_ctx(
          %{"type" => "ref/prompt", "name" => "code_review"},
          %{"name" => "language", "value" => "el"},
          %{"arguments" => nil}
        )

      assert is_nil(ctx.error)
      assert ctx.completion_context == nil
    end

    test "returns rpc_bad_arguments when a context argument value is not a string" do
      bad_values = [1, nil, ["x"], %{"y" => "z"}, true]

      for value <- bad_values do
        ctx =
          completion_ctx(
            %{"type" => "ref/prompt", "name" => "code_review"},
            %{"name" => "language", "value" => "el"},
            %{"arguments" => %{"focus" => value}}
          )

        refute is_nil(ctx.error)
        assert ctx.error.code == :rpc_bad_arguments
      end
    end

    test "returns rpc_invalid_ref when ref is missing" do
      ctx = completion_ctx(nil, %{"name" => "language", "value" => "el"})

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_ref
    end

    test "returns rpc_invalid_ref when ref type is unknown" do
      ctx =
        completion_ctx(%{"type" => "ref/other", "name" => "code_review"}, %{
          "name" => "x",
          "value" => "y"
        })

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_ref
    end

    test "returns rpc_bad_arguments when argument is missing" do
      ctx = completion_ctx(%{"type" => "ref/prompt", "name" => "code_review"}, nil)

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_bad_arguments
    end

    test "returns rpc_bad_arguments when the argument value is not a string" do
      ctx =
        completion_ctx(%{"type" => "ref/prompt", "name" => "code_review"}, %{
          "name" => "language",
          "value" => 1
        })

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_bad_arguments
    end

    test "returns rpc_bad_arguments when the context is not a map" do
      ctx =
        completion_ctx(
          %{"type" => "ref/prompt", "name" => "code_review"},
          %{"name" => "language", "value" => "el"},
          "nope"
        )

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_bad_arguments
    end

    test "returns rpc_prompt_not_found for an unknown prompt" do
      ctx =
        completion_ctx(%{"type" => "ref/prompt", "name" => "missing"}, %{
          "name" => "x",
          "value" => "y"
        })

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_prompt_not_found
    end

    test "returns rpc_resource_not_found for an unknown resource" do
      ctx =
        completion_ctx(
          %{"type" => "ref/resource", "uri" => "file:///missing.md"},
          %{"name" => "x", "value" => "y"}
        )

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_resource_not_found
      assert ctx.error.data == %{"uri" => "file:///missing.md"}
    end

    test "returns rpc_method_not_found when the resolved module has no complete/4" do
      body = %{
        "id" => 1,
        "method" => "completion/complete",
        "params" => %{
          "ref" => %{"type" => "ref/prompt", "name" => "no_complete"},
          "argument" => %{"name" => "x", "value" => "y"}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.CompletionsNoCallback, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end
  end

  describe "validate/1 - params (logging setLevel)" do
    @logging_server Servers.WithLogging
    @log_levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]

    test "sets log_level in context for each valid level" do
      Enum.each(@log_levels, fn level ->
        body = %{
          "id" => 1,
          "method" => "logging/setLevel",
          "params" => %{"level" => to_string(level)}
        }

        ctx = validate_and_bind(context(build_conn_with_server(@logging_server, body)))

        assert is_nil(ctx.error)
        assert ctx.log_level == level
      end)
    end

    test "returns with rpc error when level is unknown" do
      body = %{"id" => 1, "method" => "logging/setLevel", "params" => %{"level" => "verbose"}}

      ctx = validate_and_bind(context(build_conn_with_server(@logging_server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_log_level
    end

    test "returns with rpc error when level is missing" do
      body = %{"id" => 1, "method" => "logging/setLevel", "params" => %{}}

      ctx = validate_and_bind(context(build_conn_with_server(@logging_server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_log_level
    end

    test "returns with rpc error when params are missing" do
      body = %{"id" => 1, "method" => "logging/setLevel"}

      ctx = validate_and_bind(context(build_conn_with_server(@logging_server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_missing_params
    end

    test "returns with rpc error when level is not a string" do
      body = %{"id" => 1, "method" => "logging/setLevel", "params" => %{"level" => 123}}

      ctx = validate_and_bind(context(build_conn_with_server(@logging_server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_log_level
    end
  end

  describe "validate/1 - params (resources subscribe)" do
    @subscribed_server Servers.ResourcesMultipleSubscribed

    test "requires rpc id for resources/subscribe when subscribe capability is true" do
      body = %{
        "method" => "resources/subscribe",
        "params" => %{"uri" => "file:///marketing.md"}
      }

      ctx = validate_and_bind(context(build_conn_with_server(@subscribed_server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_missing_id
    end

    test "requires rpc id for resources/unsubscribe when subscribe capability is true" do
      body = %{
        "method" => "resources/unsubscribe",
        "params" => %{"uri" => "file:///marketing.md"}
      }

      ctx = validate_and_bind(context(build_conn_with_server(@subscribed_server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_missing_id
    end

    test "returns with rpc error when uri is missing for resources/subscribe" do
      body = %{"id" => 1, "method" => "resources/subscribe", "params" => %{}}
      ctx = validate_and_bind(context(build_conn_with_server(@subscribed_server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_missing_uri_parameter
    end

    test "returns with rpc error when uri is missing for resources/unsubscribe" do
      body = %{"id" => 1, "method" => "resources/unsubscribe", "params" => %{}}
      ctx = validate_and_bind(context(build_conn_with_server(@subscribed_server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_missing_uri_parameter
    end

    test "returns with rpc error when uri is nil for resources/subscribe" do
      body = %{"id" => 1, "method" => "resources/subscribe", "params" => %{"uri" => nil}}
      ctx = validate_and_bind(context(build_conn_with_server(@subscribed_server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_missing_uri_parameter
    end

    test "returns with rpc error when uri is not a string for resources/unsubscribe" do
      body = %{"id" => 1, "method" => "resources/unsubscribe", "params" => %{"uri" => 123}}
      ctx = validate_and_bind(context(build_conn_with_server(@subscribed_server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_missing_uri_parameter
    end

    test "returns with rpc_resource_not_found error when uri does not match any resource or template for resources/subscribe" do
      body = %{
        "id" => 1,
        "method" => "resources/subscribe",
        "params" => %{"uri" => "file:///nonexistent.md"}
      }

      ctx = validate_and_bind(context(build_conn_with_server(@subscribed_server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_resource_not_found
      assert ctx.error.data == %{"uri" => "file:///nonexistent.md"}
    end

    test "passes when uri matches a resource for resources/subscribe" do
      body = %{
        "id" => 1,
        "method" => "resources/subscribe",
        "params" => %{"uri" => "file:///marketing.md"}
      }

      ctx = validate_and_bind(context(build_conn_with_server(@subscribed_server, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.kind == :resource
      assert ctx.bound.module == Support.Entities.Resources.FirstTest
      assert ctx.bound.entity.uri == "file:///marketing.md"
      assert ctx.bound.uri_params == nil
    end

    test "passes when uri matches a template for resources/subscribe" do
      body = %{
        "id" => 1,
        "method" => "resources/subscribe",
        "params" => %{"uri" => "file://docs/intro.md"}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.WithTemplates, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.kind == :template
      assert ctx.bound.module == Support.Entities.Templates.FirstTest
      assert ctx.bound.uri_params == %{"path" => "intro.md"}
    end
  end

  # -------------------------------------------------------------------
  # validate/1 - initialize params
  # -------------------------------------------------------------------

  describe "validate/1 - initialize params" do
    @initialize_params %{
      "protocolVersion" => "2025-11-25",
      "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"}
    }

    test "passes and sets negotiated version, client info and capabilities" do
      params =
        Map.put(@initialize_params, "capabilities", %{"roots" => %{"listChanged" => true}})

      body = %{"id" => 1, "method" => "initialize", "params" => params}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      assert is_nil(ctx.error)
      assert ctx.negotiated_protocol_version == "2025-11-25"
      assert ctx.client_info == %{"name" => "test-client", "version" => "1.0.0"}
      assert ctx.client_capabilities == %{"roots" => %{"listChanged" => true}}
    end

    test "defaults client capabilities to an empty map" do
      body = %{"id" => 1, "method" => "initialize", "params" => @initialize_params}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      assert is_nil(ctx.error)
      assert ctx.client_capabilities == %{}
    end

    for bad <- ["roots", [], 1, true] do
      test "capabilities #{inspect(bad)} is refused" do
        params = Map.put(@initialize_params, "capabilities", unquote(Macro.escape(bad)))
        body = %{"id" => 1, "method" => "initialize", "params" => params}

        ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

        refute is_nil(ctx.error)
        assert ctx.error.code == :rpc_invalid_capabilities
      end
    end

    test "capabilities null gives an empty map" do
      params = Map.put(@initialize_params, "capabilities", nil)
      body = %{"id" => 1, "method" => "initialize", "params" => params}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      assert is_nil(ctx.error)
      assert ctx.client_capabilities == %{}
    end

    test "initialize with no params still gives the protocol version error" do
      body = %{"id" => 1, "method" => "initialize"}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_protocol_version
    end

    test "keeps the requested version when it is supported" do
      body = %{"id" => 1, "method" => "initialize", "params" => @initialize_params}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      assert is_nil(ctx.error)
      assert ctx.negotiated_protocol_version == "2025-11-25"
    end

    test "falls back to the latest supported version when requested version is unsupported" do
      params = Map.put(@initialize_params, "protocolVersion", "2024-11-05")
      body = %{"id" => 1, "method" => "initialize", "params" => params}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      assert is_nil(ctx.error)
      assert ctx.negotiated_protocol_version == OzMcp.Protocol.latest()
    end

    test "returns with rpc error when params are missing" do
      body = %{"id" => 1, "method" => "initialize"}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_protocol_version
    end

    test "returns with rpc error when protocolVersion is missing" do
      params = Map.delete(@initialize_params, "protocolVersion")
      body = %{"id" => 1, "method" => "initialize", "params" => params}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_protocol_version
    end

    test "returns with rpc error when protocolVersion is empty" do
      params = Map.put(@initialize_params, "protocolVersion", "")
      body = %{"id" => 1, "method" => "initialize", "params" => params}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_protocol_version
    end

    test "returns with rpc error when protocolVersion is not a string" do
      params = Map.put(@initialize_params, "protocolVersion", 123)
      body = %{"id" => 1, "method" => "initialize", "params" => params}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_protocol_version
    end

    test "returns with rpc error when clientInfo is missing" do
      params = Map.delete(@initialize_params, "clientInfo")
      body = %{"id" => 1, "method" => "initialize", "params" => params}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_client_info
    end

    test "returns with rpc error when clientInfo is not a map" do
      params = Map.put(@initialize_params, "clientInfo", "not-a-map")
      body = %{"id" => 1, "method" => "initialize", "params" => params}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_client_info
    end

    test "returns with rpc error when clientInfo name key is missing" do
      params = Map.put(@initialize_params, "clientInfo", %{"version" => "1.0.0"})
      body = %{"id" => 1, "method" => "initialize", "params" => params}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_client_info
    end

    test "returns with rpc error when clientInfo version key is missing" do
      params = Map.put(@initialize_params, "clientInfo", %{"name" => "test-client"})
      body = %{"id" => 1, "method" => "initialize", "params" => params}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_client_info
    end

    test "passes when clientInfo name and version are empty strings (presence only)" do
      params =
        Map.put(@initialize_params, "clientInfo", %{"name" => "", "version" => ""})

      body = %{"id" => 1, "method" => "initialize", "params" => params}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      assert is_nil(ctx.error)
      assert ctx.client_info == %{"name" => "", "version" => ""}
    end

    test "returns with rpc error when clientInfo name is nil" do
      params =
        Map.put(@initialize_params, "clientInfo", %{"name" => nil, "version" => "1.0.0"})

      body = %{"id" => 1, "method" => "initialize", "params" => params}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_client_info
    end

    test "returns with rpc error when clientInfo version is nil" do
      params =
        Map.put(@initialize_params, "clientInfo", %{"name" => "test-client", "version" => nil})

      body = %{"id" => 1, "method" => "initialize", "params" => params}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_client_info
    end

    test "returns with rpc error when clientInfo name is not a string" do
      params =
        Map.put(@initialize_params, "clientInfo", %{"name" => 123, "version" => "1.0.0"})

      body = %{"id" => 1, "method" => "initialize", "params" => params}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_invalid_client_info
    end

    test "passes through for non-initialize methods without touching negotiation fields" do
      body = %{"id" => 1, "method" => "ping"}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      assert is_nil(ctx.error)
      assert ctx.negotiated_protocol_version == nil
      assert ctx.client_info == nil
      assert ctx.client_capabilities == %{}
    end
  end

  # -------------------------------------------------------------------
  # validate/1 - capabilities
  # -------------------------------------------------------------------

  describe "validate/1 - capabilities" do
    test "returns with rpc error for tools/list when tools is nil" do
      body = %{"id" => 1, "method" => "tools/list"}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ResourcesSingle, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "returns with rpc error for tools/call when tools is nil" do
      body = %{"id" => 1, "method" => "tools/call", "params" => %{}}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ResourcesSingle, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "returns with rpc error for resources/list when resources is nil" do
      body = %{"id" => 1, "method" => "resources/list"}

      ctx =
        validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "returns with rpc error for resources/templates/list when resources is nil" do
      body = %{"id" => 1, "method" => "resources/templates/list"}

      ctx =
        validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "returns with rpc error for resources/read when resources is nil" do
      body = %{"id" => 1, "method" => "resources/read", "params" => %{}}

      ctx =
        validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "returns with rpc error for resources/subscribe when resources is nil" do
      body = %{"id" => 1, "method" => "resources/subscribe", "params" => %{}}

      ctx =
        validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "returns with rpc error for resources/unsubscribe when resources is nil" do
      body = %{"id" => 1, "method" => "resources/unsubscribe", "params" => %{}}

      ctx =
        validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "returns with rpc error for resources/subscribe when subscribe is false" do
      body = %{"id" => 1, "method" => "resources/subscribe", "params" => %{}}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "returns with rpc error for resources/unsubscribe when subscribe is false" do
      body = %{"id" => 1, "method" => "resources/unsubscribe", "params" => %{}}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "passes for resources/subscribe when subscribe is true" do
      body = %{
        "id" => 1,
        "method" => "resources/subscribe",
        "params" => %{"uri" => "file:///marketing.md"}
      }

      ctx =
        validate_and_bind(
          context(build_conn_with_server(Servers.ResourcesMultipleSubscribed, body))
        )

      assert is_nil(ctx.error)
    end

    test "passes for resources/list when resources is configured" do
      body = %{"id" => 1, "method" => "resources/list"}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      assert is_nil(ctx.error)
    end

    test "passes for resources/templates/list when resources is configured" do
      body = %{"id" => 1, "method" => "resources/templates/list"}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.WithTemplates, body)))

      assert is_nil(ctx.error)
    end

    test "passes for resources/read when resources is configured" do
      body = %{
        "id" => 1,
        "method" => "resources/read",
        "params" => %{"uri" => "file:///marketing.md"}
      }

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      assert is_nil(ctx.error)
    end

    test "returns with rpc error for logging/setLevel when logging capability is absent" do
      body = %{"id" => 1, "method" => "logging/setLevel", "params" => %{"level" => "info"}}

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "passes for logging/setLevel when logging capability is declared" do
      body = %{"id" => 1, "method" => "logging/setLevel", "params" => %{"level" => "info"}}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.WithLogging, body)))

      assert is_nil(ctx.error)
    end

    test "returns with rpc error for completion/complete when completions capability is absent" do
      body = %{
        "id" => 1,
        "method" => "completion/complete",
        "params" => %{
          "ref" => %{"type" => "ref/prompt", "name" => "code_review"},
          "argument" => %{"name" => "language", "value" => "el"}
        }
      }

      ctx = validate_and_bind(context(build_conn_with_server(@server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "passes for completion/complete when the canonical empty capability is declared" do
      body = %{
        "id" => 1,
        "method" => "completion/complete",
        "params" => %{
          "ref" => %{"type" => "ref/prompt", "name" => "code_review"},
          "argument" => %{"name" => "language", "value" => "el"}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.Completions, body)))

      assert is_nil(ctx.error)
    end
  end

  # -------------------------------------------------------------------
  # validate/1 - arguments
  # -------------------------------------------------------------------

  describe "validate/1 - arguments" do
    test "returns with rpc error when tool is not found" do
      body = %{"id" => 1, "method" => "tools/call", "params" => %{"name" => "nonexistent"}}

      ctx =
        validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_tool_not_found
      assert ctx.error.data == %{"name" => "nonexistent"}
    end

    test "tool with no arguments, no arguments sent" do
      body = %{"id" => 1, "method" => "tools/call", "params" => %{"name" => "get_time"}}

      ctx =
        validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      assert is_nil(ctx.error)
    end

    test "tool with no arguments, empty arguments sent" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "get_time", "arguments" => %{}}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      assert is_nil(ctx.error)
    end

    test "tool with no arguments, arguments of null run the tool with an empty map" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "get_time", "arguments" => nil}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.arguments == %{}
    end

    test "a nil argument at a deeper level is kept in the params" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "get_date", "arguments" => %{"extra" => nil}}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      assert is_nil(ctx.error)
      assert ctx.rpc_params["arguments"] == %{"extra" => nil}
    end

    test "tool with no arguments, extra arguments sent" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "get_date", "arguments" => %{"extra" => 1}}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      # The tool schema declares no properties and no additionalProperties
      # constraint: the author schema is validated as-is, so extra arguments
      # are accepted and reach the callback untouched.
      #
      assert is_nil(ctx.error)
      assert is_nil(ctx.bound.input_errors)
      assert ctx.rpc_params["arguments"] == %{"extra" => 1}
    end

    test "returns a -32602 rpc error when arguments is not an object" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "get_temperature", "arguments" => ["Paris"]}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsMultiple, body)))

      assert_bad_argument(ctx, [
        "invalid type for argument 'arguments': expected 'object', got 'array'"
      ])
    end

    test "tool with required arg, all valid" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "get_temperature", "arguments" => %{"location" => "Paris"}}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsMultiple, body)))

      assert is_nil(ctx.error)
      assert is_nil(ctx.bound.input_errors)
    end

    test "tool with required arg, missing arguments key" do
      body = %{"id" => 1, "method" => "tools/call", "params" => %{"name" => "get_temperature"}}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsMultiple, body)))

      assert_tool_input_errors(ctx, ["property 'location' is required"])
    end

    test "tool with required arg, missing required arg" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "get_temperature", "arguments" => %{}}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsMultiple, body)))

      assert_tool_input_errors(ctx, ["property 'location' is required"])
    end

    test "schema violations leave the rpc error empty and resolve the tool" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "get_temperature", "arguments" => %{"location" => 123}}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsMultiple, body)))

      assert_tool_input_errors(ctx, ["'location' value is not of type string"])
      assert ctx.bound.module == Support.Entities.Tools.FirstTest
      assert ctx.rpc_params["arguments"] == %{"location" => 123}
    end

    test "the input schema is validated with the root of the catalog" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "get_temperature", "arguments" => %{"location" => "Paris"}}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsMultiple, body)))

      assert is_nil(ctx.error)

      catalog = OzMcp.Catalog.fetch(Servers.ToolsMultiple)

      assert {:ok, %JSV.Root{}} =
               OzMcp.Catalog.fetch_root(
                 catalog,
                 Support.Entities.Tools.FirstTest,
                 "get_temperature",
                 :input,
                 %{}
               )
    end
  end

  # -------------------------------------------------------------------
  # validate/1 - arguments (all types)
  # Uses the "All types" properties of input_schema_tool.
  # -------------------------------------------------------------------

  describe "validate/1 - arguments (all types)" do
    test "multiple required args, all valid" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "Alice", "integer_1" => 30}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert is_nil(ctx.error)
    end

    test "multiple required args, one missing" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "Alice"}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert_tool_input_errors(ctx, ["property 'integer_1' is required"])
    end

    test "optional arg provided with correct type" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "Alice", "integer_1" => 30, "boolean_1" => true}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert is_nil(ctx.error)
    end

    test "optional arg provided with wrong type" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "Alice", "integer_1" => 30, "number_1" => "high"}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert_tool_input_errors(ctx, [
        "'number_1' value is not of type number"
      ])
    end

    test "unknown argument provided" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "Alice", "integer_1" => 30, "unknown" => "x"}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      # The tool schema declares no additionalProperties constraint: extra
      # arguments are accepted and reach the callback untouched.
      #
      assert is_nil(ctx.error)
      assert is_nil(ctx.bound.input_errors)
      assert ctx.rpc_params["arguments"]["unknown"] == "x"
    end

    test "string type validation fails with integer" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => 123, "integer_1" => 30}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert_tool_input_errors(ctx, [
        "'string_1' value is not of type string"
      ])
    end

    test "integer type validation fails with float" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "A", "integer_1" => 30.5}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert_tool_input_errors(ctx, [
        "'integer_1' value is not of type integer"
      ])
    end

    test "boolean type validation passes with false" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "A", "integer_1" => 30, "boolean_1" => false}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert is_nil(ctx.error)
    end

    test "number type validation passes with integer" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "A", "integer_1" => 30, "number_1" => 95}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert is_nil(ctx.error)
    end

    test "number type validation passes with float" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "A", "integer_1" => 30, "number_1" => 95.5}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert is_nil(ctx.error)
    end

    test "array type validation passes with list" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "A", "integer_1" => 30, "array_1" => ["a", "b"]}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert is_nil(ctx.error)
    end

    test "object type validation passes with map" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "A", "integer_1" => 30, "object_1" => %{"k" => "v"}}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert is_nil(ctx.error)
    end
  end

  # -------------------------------------------------------------------
  # validate/1 - arguments (with defaults)
  # Uses the "With defaults" properties of input_schema_tool.
  # -------------------------------------------------------------------

  describe "validate/1 - arguments (with defaults)" do
    test "defaults are applied to params when arguments are missing" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "Alice", "integer_1" => 30}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.params["arguments"]["string_1"] == "Alice"
      assert ctx.bound.params["arguments"]["integer_1"] == 30
      assert ctx.bound.params["arguments"]["string_2"] == "default_2"
      assert ctx.bound.params["arguments"]["integer_2"] == 2
    end

    test "defaults do not override provided values" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{
            "string_1" => "Alice",
            "integer_1" => 30,
            "string_2" => "custom",
            "integer_2" => 99
          }
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.params["arguments"]["string_2"] == "custom"
      assert ctx.bound.params["arguments"]["integer_2"] == 99
    end

    test "defaults fill only missing optional args" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "Alice", "integer_1" => 30, "string_2" => "custom"}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.params["arguments"]["string_2"] == "custom"
      assert ctx.bound.params["arguments"]["integer_2"] == 2
    end
  end

  # -------------------------------------------------------------------
  # validate/1 - arguments (all constraints)
  # Uses the "All constraints" properties of input_schema_tool.
  # string_1/integer_1 are sent as the required base.
  # -------------------------------------------------------------------

  describe "validate/1 - arguments (all constraints)" do
    test "number type accepts integer but exclusiveMinimum rejects at boundary" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "x", "integer_1" => 1, "float_3" => 0}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert_tool_input_errors(ctx, [
        "'float_3' value 0 is not higher than exclusive minimum 0.0"
      ])
    end

    test "number type accepts float" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "x", "integer_1" => 1, "float_3" => 0.5}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert is_nil(ctx.error)
    end

    test "minimum constraint rejects value below minimum" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "x", "integer_1" => 1, "integer_3" => -1}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert_tool_input_errors(ctx, ["'integer_3' value -1 is lower than minimum 0"])
    end

    test "minimum constraint passes at boundary" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "x", "integer_1" => 1, "integer_3" => 0}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert is_nil(ctx.error)
    end

    test "maximum constraint rejects value above maximum" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "x", "integer_1" => 1, "integer_3" => 200}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      refute is_nil(ctx.bound.input_errors)
    end

    test "exclusiveMinimum rejects at boundary" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "x", "integer_1" => 1, "float_3" => 0.0}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      refute is_nil(ctx.bound.input_errors)
    end

    test "exclusiveMaximum rejects at boundary" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "x", "integer_1" => 1, "float_3" => 1.0}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      refute is_nil(ctx.bound.input_errors)
    end

    test "minLength rejects too short string" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "x", "integer_1" => 1, "string_3" => "ab"}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      refute is_nil(ctx.bound.input_errors)
    end

    test "maxLength rejects too long string" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{
            "string_1" => "x",
            "integer_1" => 1,
            "string_3" => String.duplicate("a", 21)
          }
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      refute is_nil(ctx.bound.input_errors)
    end

    test "minLength passes at boundary" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "x", "integer_1" => 1, "string_3" => "abc"}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert is_nil(ctx.error)
    end

    test "format email rejects invalid email" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "x", "integer_1" => 1, "email_3" => "notanemail"}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      refute is_nil(ctx.bound.input_errors)
    end

    test "format email accepts valid email" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{
            "string_1" => "x",
            "integer_1" => 1,
            "email_3" => "alice@example.com"
          }
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert is_nil(ctx.error)
    end

    test "format uri rejects invalid uri" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{"string_1" => "x", "integer_1" => 1, "uri_3" => "notaurl"}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      refute is_nil(ctx.bound.input_errors)
    end

    test "format uri accepts valid uri" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{
            "string_1" => "x",
            "integer_1" => 1,
            "uri_3" => "https://example.com"
          }
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert is_nil(ctx.error)
    end

    test "all constraints pass with valid input" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{
            "string_1" => "x",
            "integer_1" => 1,
            "string_3" => "alice",
            "integer_3" => 25,
            "email_3" => "alice@example.com",
            "uri_3" => "https://example.com",
            "float_3" => 0.75
          }
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      assert is_nil(ctx.error)
    end

    test "multiple arguments fail validation simultaneously" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "input_schema_tool",
          "arguments" => %{
            "string_1" => "x",
            "integer_1" => 1,
            "string_3" => "ab",
            "integer_3" => -1,
            "email_3" => "notanemail",
            "float_3" => 0
          }
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      refute is_nil(ctx.bound.input_errors)
      assert length(ctx.bound.input_errors) == 4

      assert_tool_input_errors(ctx, [
        "'string_3' value length must be at least 3 but is 2",
        "'integer_3' value -1 is lower than minimum 0",
        "'email_3' value does not respect the 'email' format (\"invalid_email\")",
        "'float_3' value 0 is not higher than exclusive minimum 0.0"
      ])
    end
  end

  # -------------------------------------------------------------------
  # validate/1 - tasks capability gating
  # -------------------------------------------------------------------

  describe "validate/1 - tasks capability gating" do
    @tag :tasks_gating
    test "returns with rpc error for every tasks/* method when tasks capability is absent" do
      Enum.each(["tasks/get", "tasks/list", "tasks/cancel", "tasks/result"], fn method ->
        body = %{"id" => 1, "method" => method, "params" => %{}}

        ctx =
          validate_and_bind(context(build_conn_with_server(@tools_only, body)))

        refute is_nil(ctx.error)
        assert ctx.error.code == :rpc_method_not_found
      end)
    end

    test "returns with rpc error for tasks/list when the list member is absent" do
      body = %{"id" => 1, "method" => "tasks/list", "params" => %{}}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksRequestsOnly, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "returns with rpc error for tasks/cancel when the cancel member is absent" do
      body = %{"id" => 1, "method" => "tasks/cancel", "params" => %{"taskId" => "abc"}}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksRequestsOnly, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "passes tasks/list when the list member is declared" do
      body = %{"id" => 1, "method" => "tasks/list", "params" => %{}}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksTest, body)))

      assert is_nil(ctx.error)
    end

    test "passes tasks/cancel when the cancel member is declared" do
      body = %{"id" => 1, "method" => "tasks/cancel", "params" => %{"taskId" => "abc"}}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksTest, body)))

      assert is_nil(ctx.error)
    end

    test "passes tasks/get and tasks/result with only the tasks capability itself" do
      Enum.each(["tasks/get", "tasks/result"], fn method ->
        body = %{"id" => 1, "method" => method, "params" => %{"taskId" => "abc"}}

        ctx =
          validate_and_bind(context(build_conn_with_server(Servers.TasksRequestsOnly, body)))

        assert is_nil(ctx.error)
      end)
    end

    test "tolerates string-keyed capability members (non-DSL server config)" do
      body = %{"id" => 1, "method" => "tasks/list", "params" => %{}}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksStringKeyCaps, body)))

      assert is_nil(ctx.error)

      body = %{
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => "task_immediate", "task" => %{}}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksStringKeyCaps, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.task == %{ttl: nil}
    end
  end

  # -------------------------------------------------------------------
  # validate/1 - tasks params (taskId / cursor)
  # -------------------------------------------------------------------

  describe "validate/1 - tasks params (taskId)" do
    @taskid_methods ["tasks/get", "tasks/result", "tasks/cancel"]

    test "sets task_id when taskId is a non-empty string" do
      Enum.each(@taskid_methods, fn method ->
        body = %{"id" => 1, "method" => method, "params" => %{"taskId" => "task-123"}}

        ctx =
          validate_and_bind(context(build_conn_with_server(Servers.TasksTest, body)))

        assert is_nil(ctx.error)
        assert ctx.task_id == "task-123"
      end)
    end

    test "returns with rpc error when taskId is missing" do
      Enum.each(@taskid_methods, fn method ->
        body = %{"id" => 1, "method" => method, "params" => %{}}

        ctx =
          validate_and_bind(context(build_conn_with_server(Servers.TasksTest, body)))

        refute is_nil(ctx.error)
        assert ctx.error.code == :rpc_missing_taskid_parameter
      end)
    end

    test "returns with rpc error when params are missing" do
      Enum.each(@taskid_methods, fn method ->
        body = %{"id" => 1, "method" => method}

        ctx =
          validate_and_bind(context(build_conn_with_server(Servers.TasksTest, body)))

        refute is_nil(ctx.error)
        assert ctx.error.code == :rpc_missing_params
      end)
    end

    test "returns with rpc error when taskId is empty" do
      Enum.each(@taskid_methods, fn method ->
        body = %{"id" => 1, "method" => method, "params" => %{"taskId" => ""}}

        ctx =
          validate_and_bind(context(build_conn_with_server(Servers.TasksTest, body)))

        refute is_nil(ctx.error)
        assert ctx.error.code == :rpc_missing_taskid_parameter
      end)
    end

    test "returns with rpc error when taskId is nil" do
      Enum.each(@taskid_methods, fn method ->
        body = %{"id" => 1, "method" => method, "params" => %{"taskId" => nil}}

        ctx =
          validate_and_bind(context(build_conn_with_server(Servers.TasksTest, body)))

        refute is_nil(ctx.error)
        assert ctx.error.code == :rpc_missing_taskid_parameter
      end)
    end

    test "returns with rpc error when taskId is not a string" do
      Enum.each(@taskid_methods, fn method ->
        body = %{"id" => 1, "method" => method, "params" => %{"taskId" => 123}}

        ctx =
          validate_and_bind(context(build_conn_with_server(Servers.TasksTest, body)))

        refute is_nil(ctx.error)
        assert ctx.error.code == :rpc_missing_taskid_parameter
      end)
    end
  end

  describe "validate/1 - tasks params (cursor)" do
    test "passes without cursor and leaves tasks_cursor nil" do
      body = %{"id" => 1, "method" => "tasks/list"}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksTest, body)))

      assert is_nil(ctx.error)
      assert ctx.tasks_cursor == nil
    end

    test "sets tasks_cursor when cursor is a string" do
      body = %{"id" => 1, "method" => "tasks/list", "params" => %{"cursor" => "42"}}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksTest, body)))

      assert is_nil(ctx.error)
      assert ctx.tasks_cursor == "42"
    end

    test "returns with rpc error when cursor is not a string" do
      Enum.each([123, 1.5, true, %{}, []], fn cursor ->
        body = %{"id" => 1, "method" => "tasks/list", "params" => %{"cursor" => cursor}}

        ctx =
          validate_and_bind(context(build_conn_with_server(Servers.TasksTest, body)))

        refute is_nil(ctx.error)
        assert ctx.error.code == :rpc_invalid_cursor
      end)
    end

    test "treats nil cursor as absent" do
      body = %{"id" => 1, "method" => "tasks/list", "params" => %{"cursor" => nil}}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksTest, body)))

      assert is_nil(ctx.error)
    end
  end

  # -------------------------------------------------------------------
  # validate/1 - task-augmented tools/call (taskSupport matrix)
  # -------------------------------------------------------------------

  describe "validate/1 - task-augmented tools/call (taskSupport matrix)" do
    test "no capability, task absent: normal call" do
      body = %{"id" => 1, "method" => "tools/call", "params" => %{"name" => "get_date"}}

      ctx =
        validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.task == nil
    end

    test "no capability, task present: normal call, metadata ignored and stripped" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "get_date", "task" => %{"ttl" => 60_000}}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.task == nil
      refute Map.has_key?(ctx.bound.params, "task")
    end

    test "capability present, taskSupport forbidden, task absent: normal call" do
      body = %{"id" => 1, "method" => "tools/call", "params" => %{"name" => "get_date"}}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksForbiddenTool, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.task == nil
    end

    test "capability present, taskSupport forbidden, task present: rpc_method_not_found" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "get_date", "task" => %{}}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksForbiddenTool, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "capability present, taskSupport absent (defaults to forbidden), task present: rpc_method_not_found" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "get_time", "task" => %{}}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksForbiddenTool, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "capability present, taskSupport optional, task absent: normal call" do
      body = %{"id" => 1, "method" => "tools/call", "params" => %{"name" => "task_immediate"}}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksTest, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.task == nil
    end

    test "capability present, taskSupport optional, task present: task path" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "task_immediate", "task" => %{"ttl" => 5_000}}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksTest, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.task == %{ttl: 5_000}
      refute Map.has_key?(ctx.bound.params, "task")
    end

    test "capability present, taskSupport required, task absent: rpc_method_not_found" do
      body = %{"id" => 1, "method" => "tools/call", "params" => %{"name" => "full"}}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksRequiredTool, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "capability present, taskSupport required, task present: task path" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "full", "task" => %{}}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksRequiredTool, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.task == %{ttl: nil}
    end

    test "capability present, taskSupport required, task absent, arguments violate the schema: rpc_method_not_found" do
      #
      # The task support gating runs before the argument schema: the
      # missing task marker is rejected even though the arguments are
      # invalid too.
      #
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "full", "arguments" => %{"name" => 123}}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksRequiredTool, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
      assert is_nil(ctx.bound)
    end

    test "capability present, taskSupport required, task present, arguments violate the schema: input errors with task metadata" do
      #
      # The task metadata survives a schema violation: the handler answers
      # with a failed task carrying the messages, never with a plain tool
      # result (the client expects a task).
      #
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "full", "arguments" => %{"name" => 123}, "task" => %{}}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.TasksRequiredTool, body)))

      assert_tool_input_errors(ctx, ["'name' value is not of type string"])
      assert ctx.bound.task == %{ttl: nil}
    end
  end

  # -------------------------------------------------------------------
  # validate/1 - task metadata validation
  # -------------------------------------------------------------------

  describe "validate/1 - task metadata validation" do
    @task_server Servers.TasksTest

    test "returns with rpc error when task metadata is not a map" do
      Enum.each(["not-a-map", 42, true], fn task_meta ->
        body = %{
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "task_immediate", "task" => task_meta}
        }

        ctx = validate_and_bind(context(build_conn_with_server(@task_server, body)))

        refute is_nil(ctx.error)
        assert ctx.error.code == :rpc_bad_task_metadata
      end)
    end

    test "returns with rpc error when ttl is not an integer" do
      Enum.each(["5000", 1.5, true, %{}], fn ttl ->
        body = %{
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "task_immediate", "task" => %{"ttl" => ttl}}
        }

        ctx = validate_and_bind(context(build_conn_with_server(@task_server, body)))

        refute is_nil(ctx.error)
        assert ctx.error.code == :rpc_bad_task_metadata
      end)
    end

    test "returns with rpc error when ttl is negative" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "task_immediate", "task" => %{"ttl" => -1}}
      }

      ctx = validate_and_bind(context(build_conn_with_server(@task_server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_bad_task_metadata
    end

    test "returns with rpc error when ttl is zero" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "task_immediate", "task" => %{"ttl" => 0}}
      }

      ctx = validate_and_bind(context(build_conn_with_server(@task_server, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_bad_task_metadata
    end

    test "task of null follows the path with no task" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "task_immediate", "task" => nil}
      }

      ctx = validate_and_bind(context(build_conn_with_server(@task_server, body)))

      assert is_nil(ctx.error)
      assert is_nil(ctx.bound.task)
      refute Map.has_key?(ctx.bound.params, "task")
    end

    test "a ttl of null creates a task with the default ttl" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "task_immediate", "task" => %{"ttl" => nil}}
      }

      ctx = validate_and_bind(context(build_conn_with_server(@task_server, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.task == %{ttl: nil}
    end

    test "accepts task metadata without ttl" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "task_immediate", "task" => %{}}
      }

      ctx = validate_and_bind(context(build_conn_with_server(@task_server, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.task == %{ttl: nil}
    end

    test "arguments are still validated as a plain call when the server ignores the task marker" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "input_schema_tool", "task" => %{}}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.ToolsAllArguments, body)))

      # The server does not advertise the tasks capability, so the task
      # marker is stripped and the request is validated as a plain call:
      # the schema violations are collected and the handler answers with
      # an isError result instead of creating a task.
      #
      assert_tool_input_errors(ctx, [
        "properties 'string_1' and 'integer_1' are required"
      ])

      assert is_nil(ctx.bound.task)
    end

    test "post-041 regression: augmented call keeps progress_token alongside the task metadata" do
      body = %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "task_immediate",
          "task" => %{"ttl" => 1_000},
          "_meta" => %{"progressToken" => "tok-9"}
        }
      }

      ctx = validate_and_bind(context(build_conn_with_server(@task_server, body)))

      assert is_nil(ctx.error)
      assert ctx.progress_token == "tok-9"
      assert ctx.bound.task == %{ttl: 1_000}
    end
  end

  # -------------------------------------------------------------------
  # validate/1 - prompts capability gating
  # -------------------------------------------------------------------

  describe "validate/1 - prompts capability gating" do
    test "returns with rpc error for prompts/list when prompts is nil" do
      body = %{"id" => 1, "method" => "prompts/list"}

      ctx =
        validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "returns with rpc error for prompts/get when prompts is nil" do
      body = %{"id" => 1, "method" => "prompts/get", "params" => %{}}

      ctx =
        validate_and_bind(context(build_conn_with_server(@tools_only, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_method_not_found
    end

    test "passes for prompts/list when prompts is configured" do
      body = %{"id" => 1, "method" => "prompts/list"}

      ctx = validate_and_bind(context(build_conn_with_server(Servers.PromptsOnly, body)))

      assert is_nil(ctx.error)
    end

    test "passes for prompts/get when prompts is configured" do
      body = %{
        "id" => 1,
        "method" => "prompts/get",
        "params" => %{"name" => "code_review", "arguments" => %{"language" => "elixir"}}
      }

      ctx = validate_and_bind(context(build_conn_with_server(Servers.PromptsOnly, body)))

      assert is_nil(ctx.error)
    end
  end

  # -------------------------------------------------------------------
  # validate/1 - prompts/get params
  # -------------------------------------------------------------------

  describe "validate/1 - prompts/get params" do
    test "returns with rpc error when name is missing" do
      body = %{"id" => 1, "method" => "prompts/get", "params" => %{}}

      ctx = validate_and_bind(context(build_conn_with_server(Servers.PromptsOnly, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_missing_name_parameter
    end

    test "returns with rpc error when name is not a string" do
      body = %{"id" => 1, "method" => "prompts/get", "params" => %{"name" => 42}}

      ctx = validate_and_bind(context(build_conn_with_server(Servers.PromptsOnly, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_missing_name_parameter
    end

    test "returns with rpc error when params are absent" do
      body = %{"id" => 1, "method" => "prompts/get"}

      ctx = validate_and_bind(context(build_conn_with_server(Servers.PromptsOnly, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_missing_params
    end

    test "returns with rpc error when prompt is not found" do
      body = %{"id" => 1, "method" => "prompts/get", "params" => %{"name" => "nonexistent"}}

      ctx = validate_and_bind(context(build_conn_with_server(Servers.PromptsOnly, body)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :rpc_prompt_not_found
    end

    test "passes with rpc_params left untouched and prompt_module set" do
      body = %{
        "id" => 1,
        "method" => "prompts/get",
        "params" => %{
          "name" => "code_review",
          "arguments" => %{"language" => "elixir"}
        }
      }

      ctx = validate_and_bind(context(build_conn_with_server(Servers.PromptsOnly, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.module == Support.Entities.Prompts.FirstTest

      assert ctx.rpc_params == %{
               "name" => "code_review",
               "arguments" => %{"language" => "elixir"}
             }
    end

    test "leaves rpc_params identical to the wire params" do
      body = %{
        "id" => 1,
        "method" => "prompts/get",
        "params" => %{
          "name" => "code_review",
          "arguments" => %{"language" => "elixir"},
          "_meta" => %{"progressToken" => "tok-1"}
        }
      }

      ctx = validate_and_bind(context(build_conn_with_server(Servers.PromptsOnly, body)))

      assert is_nil(ctx.error)

      assert ctx.rpc_params == %{
               "name" => "code_review",
               "arguments" => %{"language" => "elixir"},
               "_meta" => %{"progressToken" => "tok-1"}
             }
    end

    test "missing required argument when arguments are absent" do
      body = %{"id" => 1, "method" => "prompts/get", "params" => %{"name" => "code_review"}}

      ctx = validate_and_bind(context(build_conn_with_server(Servers.PromptsOnly, body)))

      assert_bad_argument(ctx, ["missing required argument: 'language'"])
    end

    test "arguments default to an empty map when the prompt declares none" do
      body = %{"id" => 1, "method" => "prompts/get", "params" => %{"name" => "greeting"}}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.PromptsMultiple, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.module == Support.Entities.Prompts.SecondTest
      refute Map.has_key?(ctx.rpc_params, "arguments")
    end

    test "arguments of null run the prompt with an empty map" do
      body = %{
        "id" => 1,
        "method" => "prompts/get",
        "params" => %{"name" => "greeting", "arguments" => nil}
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.PromptsMultiple, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.arguments == %{}
      assert ctx.bound.params == %{"name" => "greeting"}
    end

    test "returns with rpc error when arguments is not a map" do
      body = %{
        "id" => 1,
        "method" => "prompts/get",
        "params" => %{"name" => "code_review", "arguments" => "not-a-map"}
      }

      ctx = validate_and_bind(context(build_conn_with_server(Servers.PromptsOnly, body)))

      assert_bad_argument(ctx, [
        "invalid type for argument 'arguments': expected 'object', got 'string'"
      ])
    end

    test "returns with rpc error on unknown argument" do
      body = %{
        "id" => 1,
        "method" => "prompts/get",
        "params" => %{
          "name" => "code_review",
          "arguments" => %{"language" => "elixir", "focus" => "security"}
        }
      }

      ctx = validate_and_bind(context(build_conn_with_server(Servers.PromptsOnly, body)))

      assert_bad_argument(ctx, ["unknown argument: 'focus'"])
    end

    test "returns with rpc error on non-string argument value" do
      body = %{
        "id" => 1,
        "method" => "prompts/get",
        "params" => %{
          "name" => "code_review",
          "arguments" => %{"language" => 42}
        }
      }

      ctx = validate_and_bind(context(build_conn_with_server(Servers.PromptsOnly, body)))

      assert_bad_argument(ctx, [
        "invalid type for argument 'language': expected 'string', got 'integer'"
      ])
    end

    test "leaves rpc_params untouched when arguments are invalid" do
      body = %{
        "id" => 1,
        "method" => "prompts/get",
        "params" => %{"name" => "code_review", "arguments" => %{"language" => 42}}
      }

      ctx = validate_and_bind(context(build_conn_with_server(Servers.PromptsOnly, body)))

      assert_bad_argument(ctx, [
        "invalid type for argument 'language': expected 'string', got 'integer'"
      ])

      assert ctx.rpc_params == %{"name" => "code_review", "arguments" => %{"language" => 42}}
    end

    test "accepts an empty-string argument value" do
      body = %{
        "id" => 1,
        "method" => "prompts/get",
        "params" => %{
          "name" => "code_review",
          "arguments" => %{"language" => ""}
        }
      }

      ctx = validate_and_bind(context(build_conn_with_server(Servers.PromptsOnly, body)))

      assert is_nil(ctx.error)
      assert ctx.rpc_params["arguments"] == %{"language" => ""}
    end

    test "tolerates a plain-map prompt config with string keys" do
      body = %{
        "id" => 1,
        "method" => "prompts/get",
        "params" => %{
          "name" => "plain_prompt",
          "arguments" => %{"language" => "elixir"}
        }
      }

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.PromptsStringKeyConfig, body)))

      assert is_nil(ctx.error)
      assert ctx.bound.module == Support.Entities.Prompts.DslTest.PlainMap
      assert ctx.rpc_params["arguments"] == %{"language" => "elixir"}
    end

    test "string-key prompt config enforces required arguments" do
      body = %{"id" => 1, "method" => "prompts/get", "params" => %{"name" => "plain_prompt"}}

      ctx =
        validate_and_bind(context(build_conn_with_server(Servers.PromptsStringKeyConfig, body)))

      assert_bad_argument(ctx, ["missing required argument: 'language'"])
    end
  end

  # -------------------------------------------------------------------
  # Helpers functions
  # -------------------------------------------------------------------

  defp assert_bad_argument(ctx, expected_errors) do
    refute is_nil(ctx.error)
    assert ctx.error.code == :rpc_bad_arguments
    assert is_list(ctx.error.data)
    assert Enum.sort(ctx.error.data) == Enum.sort(expected_errors)
  end

  # Schema violations are not protocol errors: the pipeline records them on
  # the context and the handler answers with a tools/call result carrying
  # isError: true.
  #
  defp assert_tool_input_errors(ctx, expected_errors) do
    assert is_nil(ctx.error)
    assert is_list(ctx.bound.input_errors)
    assert Enum.sort(ctx.bound.input_errors) == Enum.sort(expected_errors)
  end
end
