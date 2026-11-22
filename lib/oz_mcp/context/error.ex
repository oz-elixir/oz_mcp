defmodule OzMcp.Context.Error do
  @moduledoc false

  alias OzMcp.Utils.JsonRpc

  @type data :: list() | map() | nil

  @type header :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          code: atom(),
          data: data(),
          headers: [header()]
        }

  defstruct code: nil,
            data: nil,
            headers: []

  @spec new(atom(), data(), [header()]) :: %__MODULE__{}
  def new(code, data \\ nil, headers \\ []) do
    %__MODULE__{code: code, data: data, headers: headers}
  end

  # Response headers that travel with the error (for example an
  # authorization challenge). Empty for the errors of the table that
  # carry none.
  #
  @spec headers(t()) :: [header()]
  def headers(%__MODULE__{headers: headers}), do: headers

  @type status :: 200 | 400 | 401 | 403 | 404 | 405 | 406 | 408 | 413 | 415 | 429 | 500 | 503

  # The answer of an error for a message of a given kind. The HTTP
  # status comes from the table of this module: a valid request keeps
  # the status of the table and the error of a message that is not a
  # request has no JSON-RPC answer, so its 200 becomes 400. A nil kind
  # means that the JSON-RPC validation did not run (for example a GET
  # or a DELETE): the table applies. The body of a message that is not
  # a request carries no id.
  #
  @spec build(t(), term()) :: {status(), map()}
  def build(error, rpc_id), do: build(error, rpc_id, nil)

  @spec build(t(), term(), OzMcp.Context.rpc_kind()) :: {status(), map()}
  def build(error, rpc_id, kind) when kind in [:request, nil] do
    {status, rpc_code, message} = of_code(error.code, kind)
    {status, JsonRpc.error(rpc_id, rpc_code, message, error.data)}
  end

  def build(error, _rpc_id, kind) do
    {status, rpc_code, message} = of_code(error.code, kind)
    {status, JsonRpc.error(nil, rpc_code, message, error.data)}
  end

  # One row for each code of the table: the code, the HTTP status, the
  # JSON-RPC code and the message.
  #
  @errors [
    {:http_no_accept_header, 406, -32600, "accept header is required"},
    {:http_bad_accept_header, 406, -32600,
     "client must accept both application/json and text/event-stream"},
    {:http_no_event_stream_accept_header, 406, -32600, "client must accept text/event-stream"},
    {:http_missing_session_id, 400, -32600, "missing session id"},
    {:http_invalid_session_id, 400, -32600, "invalid session id"},
    {:http_initialize_with_session_id, 400, -32600,
     "cannot call initialize and provide a mcp session id"},
    {:http_invalid_session, 404, -32001, "invalid session"},
    {:http_method_not_allowed, 405, -32600, "method not allowed"},
    {:http_not_found, 404, -32600, "not found"},
    {:http_internal_error, 500, -32603, "internal server error"},
    {:http_unavailable, 503, -32603, "server unavailable"},
    {:http_session_waiting_initialization, 400, -32600, "waiting session initialization"},
    {:http_unsupported_protocol_version, 400, -32600, "unsupported MCP protocol version"},
    {:http_protocol_version_mismatch, 400, -32600,
     "MCP protocol version does not match the session"},
    {:http_parse_error, 400, -32700, "parse error"},
    {:http_batch_not_supported, 400, -32600, "batching is not supported"},
    {:http_invalid_message, 400, -32600, "invalid request"},
    {:http_unsupported_media_type, 415, -32600, "content type must be application/json"},
    {:http_payload_too_large, 413, -32600, "request body too large"},
    {:http_request_timeout, 408, -32600, "request body timeout"},
    {:http_unauthorized, 401, -32010, "unauthorized"},
    {:http_bad_authorization, 400, -32600, "malformed authorization"},
    {:http_insufficient_scope, 403, -32011, "insufficient scope"},
    {:http_forbidden, 403, -32011, "forbidden"},
    {:http_too_many_sessions, 429, -32000, "too many sessions"},
    {:http_too_many_streams, 429, -32000, "too many streams"},
    {:rpc_invalid_request, 200, -32600, "invalid request"},
    {:rpc_duplicate_request_id, 200, -32600, "request id already in use"},
    {:rpc_missing_params, 200, -32602, "missing params"},
    {:rpc_missing_id, 200, -32600, "missing id"},
    {:rpc_invalid_protocol_version, 200, -32602, "missing or invalid protocol version"},
    {:rpc_invalid_client_info, 200, -32602, "missing or invalid client info"},
    {:rpc_invalid_progress_token, 200, -32602, "invalid progress token"},
    {:rpc_invalid_meta, 200, -32602, "invalid _meta"},
    {:rpc_invalid_capabilities, 200, -32602, "invalid capabilities"},
    {:rpc_method_not_found, 200, -32601, "method not found"},
    {:rpc_missing_uri_parameter, 200, -32602, "missing uri parameter"},
    {:rpc_missing_name_parameter, 200, -32602, "missing name parameter"},
    {:rpc_invalid_log_level, 200, -32602, "invalid log level"},
    {:rpc_missing_taskid_parameter, 200, -32602, "missing taskId parameter"},
    {:rpc_bad_task_metadata, 200, -32602, "invalid task metadata"},
    {:rpc_invalid_cursor, 200, -32602, "invalid cursor"},
    {:rpc_bad_arguments, 200, -32602, "bad argument(s)"},
    {:rpc_invalid_ref, 200, -32602, "invalid ref"},
    {:rpc_internal_error, 200, -32603, "internal server error"},
    {:rpc_invalid_tool_schema, 200, -32603, "internal error"},
    {:rpc_session_waiting_initialization, 200, -32600, "waiting session initialization"},
    {:rpc_already_initialized, 200, -32600, "session already initialized"},
    {:rpc_tool_not_found, 200, -32602, "tool not found"},
    {:rpc_resource_not_found, 200, -32002, "resource not found"},
    {:rpc_prompt_not_found, 200, -32602, "prompt not found"},
    {:rpc_request_cancelled, 200, -32800, "request cancelled"}
  ]

  codes = Enum.map(@errors, &elem(&1, 0))

  if Enum.uniq(codes) != codes do
    raise "the error table has a duplicate code: #{inspect(codes -- Enum.uniq(codes))}"
  end

  # The codes of the error table. A test can walk the list and check that
  # it holds each code of the table.
  #
  @spec codes() :: [atom()]
  def codes, do: unquote(codes)

  for {code, status, rpc_code, message} <- @errors do
    defp entry(unquote(code)), do: {unquote(status), unquote(rpc_code), unquote(message)}
  end

  # A code that the table does not know is a defect of the framework:
  # the answer is the internal server error.
  #
  defp entry(_code), do: {500, -32603, "internal server error"}

  # The error of a message that is not a request has no JSON-RPC
  # answer: its 200 becomes 400.
  #
  defp of_code(code, kind) do
    case entry(code) do
      {200, rpc_code, message} when kind in [:notification, :response, :invalid] ->
        {400, rpc_code, message}

      row ->
        row
    end
  end
end
