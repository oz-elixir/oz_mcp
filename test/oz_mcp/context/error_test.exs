defmodule OzMcp.Context.ErrorTest do
  use ExUnit.Case, async: true

  alias OzMcp.Context.Error

  describe "new/2" do
    test "builds an error with a code only" do
      assert %Error{} = error = Error.new(:rpc_missing_params)
      assert error.code == :rpc_missing_params
      assert error.data == nil
    end

    test "builds an error with a code and data" do
      error = Error.new(:rpc_resource_not_found, %{"uri" => "file:///missing.md"})

      assert error.code == :rpc_resource_not_found
      assert error.data == %{"uri" => "file:///missing.md"}
    end
  end

  describe "new/3 and headers/1" do
    test "headers/1 returns an empty list by default" do
      assert Error.new(:http_missing_session_id) |> Error.headers() == []
      assert Error.new(:rpc_bad_arguments, ["x"]) |> Error.headers() == []
    end

    test "builds an error with response headers" do
      headers = [{"www-authenticate", ~s(Bearer error="invalid_token")}]

      error = Error.new(:http_unauthorized, nil, headers)

      assert error.code == :http_unauthorized
      assert error.data == nil
      assert Error.headers(error) == headers
    end

    test "keeps several response headers in order" do
      headers = [
        {"www-authenticate", "Bearer"},
        {"cache-control", "no-store"}
      ]

      error = Error.new(:http_forbidden, nil, headers)

      assert Error.headers(error) == headers
    end

    test "the response headers never leak into the JSON-RPC body" do
      error = Error.new(:http_unauthorized, nil, [{"www-authenticate", "Bearer"}])

      {401, body} = Error.build(error, 1)

      assert body == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "error" => %{"code" => -32010, "message" => "unauthorized"}
             }
    end
  end

  describe "build/2 - JSON-RPC level errors" do
    test "every rpc_* code answers HTTP 200 with its JSON-RPC code and message" do
      specs = %{
        rpc_invalid_request: {-32600, "invalid request"},
        rpc_duplicate_request_id: {-32600, "request id already in use"},
        rpc_missing_params: {-32602, "missing params"},
        rpc_missing_id: {-32600, "missing id"},
        rpc_invalid_protocol_version: {-32602, "missing or invalid protocol version"},
        rpc_invalid_client_info: {-32602, "missing or invalid client info"},
        rpc_invalid_progress_token: {-32602, "invalid progress token"},
        rpc_invalid_meta: {-32602, "invalid _meta"},
        rpc_invalid_capabilities: {-32602, "invalid capabilities"},
        rpc_method_not_found: {-32601, "method not found"},
        rpc_missing_uri_parameter: {-32602, "missing uri parameter"},
        rpc_missing_name_parameter: {-32602, "missing name parameter"},
        rpc_invalid_log_level: {-32602, "invalid log level"},
        rpc_missing_taskid_parameter: {-32602, "missing taskId parameter"},
        rpc_bad_task_metadata: {-32602, "invalid task metadata"},
        rpc_invalid_cursor: {-32602, "invalid cursor"},
        rpc_bad_arguments: {-32602, "bad argument(s)"},
        rpc_invalid_ref: {-32602, "invalid ref"},
        rpc_internal_error: {-32603, "internal server error"},
        rpc_invalid_tool_schema: {-32603, "internal error"},
        rpc_session_waiting_initialization: {-32600, "waiting session initialization"},
        rpc_already_initialized: {-32600, "session already initialized"},
        rpc_tool_not_found: {-32602, "tool not found"},
        rpc_resource_not_found: {-32002, "resource not found"},
        rpc_prompt_not_found: {-32602, "prompt not found"},
        rpc_request_cancelled: {-32800, "request cancelled"}
      }

      for {code, {rpc_code, message}} <- specs do
        assert {200, body} = Error.build(Error.new(code), 1)

        assert body == %{
                 "jsonrpc" => "2.0",
                 "id" => 1,
                 "error" => %{"code" => rpc_code, "message" => message}
               },
               "unexpected envelope for #{inspect(code)}"
      end
    end

    test "echoes the request id (integer and string)" do
      assert {200, %{"id" => 42}} = Error.build(Error.new(:rpc_method_not_found), 42)
      assert {200, %{"id" => "abc"}} = Error.build(Error.new(:rpc_method_not_found), "abc")
    end

    test "omits the id member when the request id is nil" do
      {200, body} = Error.build(Error.new(:rpc_method_not_found), nil)

      refute Map.has_key?(body, "id")
    end

    test "omits the id member when the request id is not a string or integer" do
      {200, body} = Error.build(Error.new(:rpc_method_not_found), %{"bogus" => true})

      refute Map.has_key?(body, "id")
    end

    test "carries the error data when present" do
      error = Error.new(:rpc_resource_not_found, %{"uri" => "file:///missing.md"})

      {200, body} = Error.build(error, 1)

      assert body["error"] == %{
               "code" => -32002,
               "message" => "resource not found",
               "data" => %{"uri" => "file:///missing.md"}
             }
    end

    test "carries a list of messages as data" do
      error = Error.new(:rpc_bad_arguments, ["unknown argument: 'x'"])

      {200, body} = Error.build(error, 7)

      assert body["error"]["data"] == ["unknown argument: 'x'"]
    end

    test "omits the data member when the error has none" do
      {200, body} = Error.build(Error.new(:rpc_missing_params), 1)

      assert Map.has_key?(body["error"], "data") == false
    end
  end

  describe "build/2 - HTTP level errors" do
    test "every http_* code answers with its status, JSON-RPC code and message" do
      specs = %{
        http_no_accept_header: {406, -32600, "accept header is required"},
        http_bad_accept_header:
          {406, -32600, "client must accept both application/json and text/event-stream"},
        http_no_event_stream_accept_header: {406, -32600, "client must accept text/event-stream"},
        http_missing_session_id: {400, -32600, "missing session id"},
        http_initialize_with_session_id:
          {400, -32600, "cannot call initialize and provide a mcp session id"},
        http_invalid_session: {404, -32001, "invalid session"},
        http_internal_error: {500, -32603, "internal server error"},
        http_session_waiting_initialization: {400, -32600, "waiting session initialization"},
        http_unsupported_protocol_version: {400, -32600, "unsupported MCP protocol version"},
        http_parse_error: {400, -32700, "parse error"},
        http_batch_not_supported: {400, -32600, "batching is not supported"},
        http_invalid_message: {400, -32600, "invalid request"},
        http_unsupported_media_type: {415, -32600, "content type must be application/json"},
        http_unauthorized: {401, -32010, "unauthorized"},
        http_bad_authorization: {400, -32600, "malformed authorization"},
        http_insufficient_scope: {403, -32011, "insufficient scope"},
        http_forbidden: {403, -32011, "forbidden"},
        http_too_many_sessions: {429, -32000, "too many sessions"}
      }

      for {code, {status, rpc_code, message}} <- specs do
        assert {^status, body} = Error.build(Error.new(code), 1)

        assert body == %{
                 "jsonrpc" => "2.0",
                 "id" => 1,
                 "error" => %{"code" => rpc_code, "message" => message}
               },
               "unexpected envelope for #{inspect(code)}"
      end
    end

    test "echoes a usable request id, never a forced null" do
      {_status, body} = Error.build(Error.new(:http_missing_session_id), 42)

      assert body["id"] == 42
    end

    test "omits the id member when the request id is nil" do
      {_status, body} = Error.build(Error.new(:http_missing_session_id), nil)

      refute Map.has_key?(body, "id")
    end
  end

  describe "build/2 - unknown error codes" do
    test "fall back to a 500 envelope with -32603" do
      assert {500, body} = Error.build(Error.new(:no_such_code), 42)

      assert body == %{
               "jsonrpc" => "2.0",
               "id" => 42,
               "error" => %{"code" => -32603, "message" => "internal server error"}
             }
    end
  end

  @rpc_kind_specs %{
    rpc_invalid_request: {-32600, "invalid request"},
    rpc_duplicate_request_id: {-32600, "request id already in use"},
    rpc_missing_params: {-32602, "missing params"},
    rpc_missing_id: {-32600, "missing id"},
    rpc_invalid_protocol_version: {-32602, "missing or invalid protocol version"},
    rpc_invalid_client_info: {-32602, "missing or invalid client info"},
    rpc_invalid_progress_token: {-32602, "invalid progress token"},
    rpc_invalid_meta: {-32602, "invalid _meta"},
    rpc_invalid_capabilities: {-32602, "invalid capabilities"},
    rpc_method_not_found: {-32601, "method not found"},
    rpc_missing_uri_parameter: {-32602, "missing uri parameter"},
    rpc_missing_name_parameter: {-32602, "missing name parameter"},
    rpc_invalid_log_level: {-32602, "invalid log level"},
    rpc_missing_taskid_parameter: {-32602, "missing taskId parameter"},
    rpc_bad_task_metadata: {-32602, "invalid task metadata"},
    rpc_invalid_cursor: {-32602, "invalid cursor"},
    rpc_bad_arguments: {-32602, "bad argument(s)"},
    rpc_invalid_ref: {-32602, "invalid ref"},
    rpc_internal_error: {-32603, "internal server error"},
    rpc_invalid_tool_schema: {-32603, "internal error"},
    rpc_session_waiting_initialization: {-32600, "waiting session initialization"},
    rpc_already_initialized: {-32600, "session already initialized"},
    rpc_tool_not_found: {-32602, "tool not found"},
    rpc_resource_not_found: {-32002, "resource not found"},
    rpc_prompt_not_found: {-32602, "prompt not found"},
    rpc_request_cancelled: {-32800, "request cancelled"}
  }

  @http_kind_specs %{
    http_no_accept_header: {406, -32600, "accept header is required"},
    http_bad_accept_header:
      {406, -32600, "client must accept both application/json and text/event-stream"},
    http_no_event_stream_accept_header: {406, -32600, "client must accept text/event-stream"},
    http_missing_session_id: {400, -32600, "missing session id"},
    http_invalid_session_id: {400, -32600, "invalid session id"},
    http_initialize_with_session_id:
      {400, -32600, "cannot call initialize and provide a mcp session id"},
    http_invalid_session: {404, -32001, "invalid session"},
    http_method_not_allowed: {405, -32600, "method not allowed"},
    http_not_found: {404, -32600, "not found"},
    http_internal_error: {500, -32603, "internal server error"},
    http_unavailable: {503, -32603, "server unavailable"},
    http_session_waiting_initialization: {400, -32600, "waiting session initialization"},
    http_unsupported_protocol_version: {400, -32600, "unsupported MCP protocol version"},
    http_protocol_version_mismatch:
      {400, -32600, "MCP protocol version does not match the session"},
    http_parse_error: {400, -32700, "parse error"},
    http_batch_not_supported: {400, -32600, "batching is not supported"},
    http_invalid_message: {400, -32600, "invalid request"},
    http_unsupported_media_type: {415, -32600, "content type must be application/json"},
    http_payload_too_large: {413, -32600, "request body too large"},
    http_request_timeout: {408, -32600, "request body timeout"},
    http_unauthorized: {401, -32010, "unauthorized"},
    http_bad_authorization: {400, -32600, "malformed authorization"},
    http_insufficient_scope: {403, -32011, "insufficient scope"},
    http_forbidden: {403, -32011, "forbidden"},
    http_too_many_sessions: {429, -32000, "too many sessions"},
    http_too_many_streams: {429, -32000, "too many streams"}
  }

  describe "build/3 - a message that is not a request" do
    test "every rpc_* code answers 400 with no id for a notification, a response or an invalid message" do
      for kind <- [:notification, :response, :invalid],
          {code, {rpc_code, message}} <- @rpc_kind_specs do
        assert {400, body} = Error.build(Error.new(code), 1, kind)

        assert body == %{
                 "jsonrpc" => "2.0",
                 "error" => %{"code" => rpc_code, "message" => message}
               },
               "unexpected envelope for #{inspect(code)} with kind #{inspect(kind)}"
      end
    end

    test "a request and a nil kind keep the status 200 and the id" do
      for kind <- [:request, nil] do
        assert {200, body} = Error.build(Error.new(:rpc_method_not_found), 7, kind)
        assert body["id"] == 7
      end
    end

    test "carries the error data of the code" do
      error = Error.new(:rpc_resource_not_found, %{"uri" => "file:///missing.md"})

      {400, body} = Error.build(error, 1, :notification)

      assert body["error"]["data"] == %{"uri" => "file:///missing.md"}
    end
  end

  describe "build/3 - HTTP level errors keep their status" do
    test "the status of the table holds for every kind" do
      for kind <- [:request, :notification, :response, :invalid, nil],
          {code, {status, rpc_code, message}} <- @http_kind_specs do
        assert {^status, body} = Error.build(Error.new(code), 1, kind)

        assert body["error"] == %{"code" => rpc_code, "message" => message},
               "unexpected envelope for #{inspect(code)} with kind #{inspect(kind)}"
      end
    end

    test "the body has no id for a message that is not a request" do
      for kind <- [:notification, :response, :invalid],
          {code, {_status, _rpc_code, _message}} <- @http_kind_specs do
        {_status, body} = Error.build(Error.new(code), 1, kind)

        refute Map.has_key?(body, "id"),
               "unexpected id for #{inspect(code)} with kind #{inspect(kind)}"
      end
    end

    test "a request and a nil kind keep the id" do
      for kind <- [:request, nil] do
        {_status, body} = Error.build(Error.new(:http_invalid_session), "abc", kind)
        assert body["id"] == "abc"
      end
    end

    test "an unknown code keeps the 500 of the fallback for every kind" do
      for kind <- [:request, :notification, :response, :invalid, nil] do
        {status, body} = Error.build(Error.new(:no_such_code), 1, kind)

        if kind in [:notification, :response, :invalid] do
          assert status == 500
          refute Map.has_key?(body, "id")
        else
          assert status == 500
          assert body["id"] == 1
        end
      end
    end
  end

  # The HTTP refusals keep their status for every kind of message.
  #
  @http_codes [
    {:http_no_accept_header, 406},
    {:http_bad_accept_header, 406},
    {:http_no_event_stream_accept_header, 406},
    {:http_missing_session_id, 400},
    {:http_invalid_session_id, 400},
    {:http_initialize_with_session_id, 400},
    {:http_invalid_session, 404},
    {:http_method_not_allowed, 405},
    {:http_not_found, 404},
    {:http_internal_error, 500},
    {:http_unavailable, 503},
    {:http_session_waiting_initialization, 400},
    {:http_unsupported_protocol_version, 400},
    {:http_protocol_version_mismatch, 400},
    {:http_parse_error, 400},
    {:http_batch_not_supported, 400},
    {:http_invalid_message, 400},
    {:http_unsupported_media_type, 415},
    {:http_payload_too_large, 413},
    {:http_request_timeout, 408},
    {:http_unauthorized, 401},
    {:http_bad_authorization, 400},
    {:http_insufficient_scope, 403},
    {:http_forbidden, 403},
    {:http_too_many_sessions, 429},
    {:http_too_many_streams, 429}
  ]

  # The JSON-RPC refusals travel in a 200 for a request.
  #
  @rpc_codes [
    {:rpc_invalid_request, 200},
    {:rpc_duplicate_request_id, 200},
    {:rpc_missing_params, 200},
    {:rpc_missing_id, 200},
    {:rpc_invalid_protocol_version, 200},
    {:rpc_invalid_client_info, 200},
    {:rpc_invalid_progress_token, 200},
    {:rpc_invalid_meta, 200},
    {:rpc_invalid_capabilities, 200},
    {:rpc_method_not_found, 200},
    {:rpc_missing_uri_parameter, 200},
    {:rpc_missing_name_parameter, 200},
    {:rpc_invalid_log_level, 200},
    {:rpc_missing_taskid_parameter, 200},
    {:rpc_bad_task_metadata, 200},
    {:rpc_invalid_cursor, 200},
    {:rpc_bad_arguments, 200},
    {:rpc_invalid_ref, 200},
    {:rpc_internal_error, 200},
    {:rpc_invalid_tool_schema, 200},
    {:rpc_session_waiting_initialization, 200},
    {:rpc_already_initialized, 200},
    {:rpc_tool_not_found, 200},
    {:rpc_resource_not_found, 200},
    {:rpc_prompt_not_found, 200},
    {:rpc_request_cancelled, 200}
  ]

  defp status_of(code, kind) do
    {status, _body} = Error.build(Error.new(code), 1, kind)
    status
  end

  describe "the status of the table" do
    test "each HTTP refusal keeps its status for a request and for a nil kind" do
      for {code, status} <- @http_codes do
        assert status_of(code, :request) == status
        assert status_of(code, nil) == status
      end
    end

    test "each JSON-RPC refusal travels in a 200 for a request and for a nil kind" do
      for {code, status} <- @rpc_codes do
        assert status_of(code, :request) == status
        assert status_of(code, nil) == status
      end
    end

    test "the status of an HTTP refusal does not change with the kind of the message" do
      for {code, status} <- @http_codes, kind <- [:notification, :response, :invalid] do
        assert status_of(code, kind) == status
      end
    end

    test "the 200 of a refused notification, response or invalid message becomes 400" do
      for {code, _status} <- @rpc_codes, kind <- [:notification, :response, :invalid] do
        assert status_of(code, kind) == 400
      end
    end

    test "a code the table does not know has the status 500 for every kind" do
      for kind <- [:request, :notification, :response, :invalid, nil] do
        assert status_of(:no_such_code, kind) == 500
      end
    end

    test "the lists of this test name each code of the error table" do
      listed = Enum.map(@http_codes ++ @rpc_codes, &elem(&1, 0))

      assert Enum.sort(listed) == Enum.sort(Error.codes())
    end

    test "a duplicate request id travels in a 200" do
      assert status_of(:rpc_duplicate_request_id, :request) == 200
      assert status_of(:rpc_duplicate_request_id, nil) == 200
      assert status_of(:rpc_duplicate_request_id, :notification) == 400
      assert status_of(:rpc_duplicate_request_id, :invalid) == 400
    end
  end

  describe "the table coverage" do
    test "the lists of the rpc codes and the messages name each code of the error table" do
      listed = Enum.uniq(Map.keys(@rpc_kind_specs) ++ Map.keys(@http_kind_specs))

      assert Enum.sort(listed) == Enum.sort(Error.codes())
    end

    test "a code with the prefix rpc_ travels in a 200 and a code with the prefix http_ does not" do
      for code <- Error.codes() do
        {status, _body} = Error.build(Error.new(code), 1, :request)

        if String.starts_with?(Atom.to_string(code), "rpc_") do
          assert status == 200
        else
          assert status != 200
        end
      end
    end
  end
end
