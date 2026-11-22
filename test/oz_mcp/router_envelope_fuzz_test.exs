#
# Property style fuzzing of the JSON-RPC envelope:
# For every method, every envelope field is replaced by an arbitrary
# raw JSON value and the response must never be a 5xx
# it is either a well-formed JSON-RPC response (result XOR error) or
# an empty 202 notification ack.
#
defmodule OzMcp.RouterEnvelopeFuzzTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn
  alias Support.Helpers.Utils
  alias Support.Servers

  # The instance that serves a server module in this file.
  #
  defp inst(module), do: Module.concat(module, __MODULE__)

  @cors_origin "http://localhost:3000"

  @method_servers [
    {"ping", Servers.Default},
    {"initialize", Servers.Default},
    {"tools/list", Servers.ToolsOnly},
    {"tools/call", Servers.ToolsOnly},
    {"prompts/list", Servers.PromptsOnly},
    {"prompts/get", Servers.PromptsOnly},
    {"resources/list", Servers.Default},
    {"resources/templates/list", Servers.WithTemplates},
    {"resources/read", Servers.Default},
    {"resources/subscribe", Servers.ResourcesMultipleSubscribed},
    {"resources/unsubscribe", Servers.ResourcesMultipleSubscribed},
    {"logging/setLevel", Servers.WithLogging},
    {"completion/complete", Servers.Completions},
    {"tasks/get", Servers.TasksTest},
    {"tasks/list", Servers.TasksTest},
    {"tasks/cancel", Servers.TasksTest},
    {"tasks/result", Servers.TasksTest},
    {"notifications/initialized", Servers.Default},
    {"notifications/cancelled", Servers.Default},
    {"notifications/unknown", Servers.Default},
    {"unknown/method", Servers.Default}
  ]

  @fields ["jsonrpc", "method", "id", "params"]

  # Raw JSON fragments substituted into the fuzzed field. "\"2.0\"" keeps the
  # envelope valid so the deeper validation/handler layers are exercised too.
  #
  @raw_values [
    "null",
    "true",
    "false",
    "0",
    "-1",
    "1.5",
    ~s(""),
    ~s("2.0"),
    ~s("abc"),
    "[]",
    "[1,2]",
    "{}",
    ~s({"a":1}),
    ~s({"a":{"b":[1,null]}})
  ]

  setup do
    servers = @method_servers |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    Utils.start_instances(servers, __MODULE__, allowed_origins: [])

    sessions =
      Map.new(servers, fn server ->
        {server, Utils.create_session(inst(server), initialized: true)}
      end)

    %{sessions: sessions}
  end

  test "no envelope field value ever produces a 5xx response", %{sessions: sessions} do
    Enum.each(combos(), fn {method, field, raw_value} ->
      conn = post_fuzz(method, field, raw_value, sessions)

      assert conn.status < 500,
             "5xx for method=#{method} field=#{field} value=#{raw_value}: #{conn.status}"
    end)
  end

  test "every response is a valid JSON-RPC message or an empty notification ack", %{
    sessions: sessions
  } do
    Enum.each(combos(), fn {method, field, raw_value} ->
      conn = post_fuzz(method, field, raw_value, sessions)
      context = "method=#{method} field=#{field} value=#{raw_value}"

      case conn.status do
        202 ->
          assert conn.resp_body == "", "expected an empty 202 body for #{context}"

        200 ->
          response = :json.decode(conn.resp_body)

          assert is_map(response), "non-object JSON-RPC response for #{context}"
          assert response["jsonrpc"] == "2.0", "missing jsonrpc 2.0 marker for #{context}"

          if Map.has_key?(response, "result") do
            refute Map.has_key?(response, "error"), "result and error both present for #{context}"
          else
            assert valid_error?(response["error"]), "invalid error object for #{context}"
          end

        400 ->
          #
          # A refused message that is not a request: the error body has no id.
          #
          response = :json.decode(conn.resp_body)

          assert is_map(response), "non-object JSON-RPC response for #{context}"
          assert response["jsonrpc"] == "2.0", "missing jsonrpc 2.0 marker for #{context}"
          refute Map.has_key?(response, "id"), "id in the body of a 400 for #{context}"
          assert valid_error?(response["error"]), "invalid error object for #{context}"

        status ->
          flunk("unexpected status #{status} for #{context}")
      end
    end)
  end

  test "no nested params value ever produces a 5xx or a malformed response", %{
    sessions: sessions
  } do
    Enum.each(nested_combos(), fn {method, key, raw_value} ->
      conn = post_nested(method, key, raw_value, sessions)
      context = "method=#{method} params.#{key}=#{raw_value}"

      assert conn.status in [200, 202], "unexpected status #{conn.status} for #{context}"
      assert_well_formed(conn, context)
    end)
  end

  # Keys of params replaced one level deeper than the envelope: arguments,
  # _meta, task, cursor, ref, requestId...
  #
  @nested_keys [
    {"tools/call", ["name", "arguments", "_meta", "task"]},
    {"prompts/get", ["name", "arguments"]},
    {"resources/read", ["uri"]},
    {"completion/complete", ["ref", "argument", "context"]},
    {"tasks/get", ["taskId"]},
    {"tasks/list", ["cursor"]},
    {"tasks/cancel", ["taskId"]},
    {"tasks/result", ["taskId"]},
    {"notifications/cancelled", ["requestId", "reason"]}
  ]

  defp nested_combos do
    for {method, keys} <- @nested_keys,
        key <- keys,
        raw_value <- @raw_values do
      {method, key, raw_value}
    end
  end

  defp post_nested(method, key, raw_value, sessions) do
    params =
      method
      |> params_raw()
      |> :json.decode()
      |> Map.put(key, :json.decode(raw_value))
      |> :json.encode()
      |> IO.iodata_to_binary()

    fields = method |> sane_fields() |> Map.put("params", params)

    conn =
      fields
      |> encode_fields()
      |> post_raw()
      |> put_req_header("mcp-session-id", Map.fetch!(sessions, server_of(method)))

    call_router(conn, server_of(method))
  end

  defp assert_well_formed(%{status: 202} = conn, context) do
    assert conn.resp_body == "", "expected an empty 202 body for #{context}"
  end

  defp assert_well_formed(%{status: 200} = conn, context) do
    response = :json.decode(conn.resp_body)

    assert is_map(response), "non-object JSON-RPC response for #{context}"
    assert response["jsonrpc"] == "2.0", "missing jsonrpc 2.0 marker for #{context}"

    if Map.has_key?(response, "result") do
      refute Map.has_key?(response, "error"), "result and error both present for #{context}"
    else
      assert valid_error?(response["error"]), "invalid error object for #{context}"
    end
  end

  # A refused message that is not a request: HTTP error status and the
  # error body has no id.
  #
  defp assert_well_formed(%{status: 400} = conn, context) do
    response = :json.decode(conn.resp_body)

    assert is_map(response), "non-object JSON-RPC response for #{context}"
    assert response["jsonrpc"] == "2.0", "missing jsonrpc 2.0 marker for #{context}"
    refute Map.has_key?(response, "id"), "id in the body of a 400 for #{context}"
    assert valid_error?(response["error"]), "invalid error object for #{context}"
  end

  defp combos do
    for {method, _server} <- @method_servers,
        field <- @fields,
        raw_value <- @raw_values do
      {method, field, raw_value}
    end
  end

  defp post_fuzz(method, field, raw_value, sessions) do
    body = method |> sane_fields() |> Map.put(field, raw_value) |> encode_fields()
    effective = effective_method(method, field, raw_value)

    conn = post_raw(body)

    conn =
      case session_id(effective, method, sessions) do
        nil -> conn
        session_id -> put_req_header(conn, "mcp-session-id", session_id)
      end

    call_router(conn, server_of(method))
  end

  # The fuzzed method may turn the request into another valid method; the
  # session header must match what the effective method expects. `initialize`
  # never carries a session id. notifications/initialized still gets a
  # fresh session for each call: the first notification initializes it
  # and a later one on the same session is accepted and ignored, so one
  # fresh session covers every call.
  #
  defp effective_method(method, "method", raw_value) do
    case :json.decode(raw_value) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _ -> method
    end
  end

  defp effective_method(method, _field, _raw_value), do: method

  defp session_id("notifications/initialized", _method, _sessions) do
    Utils.create_session(inst(Servers.Default))
  end

  defp session_id("initialize", _method, _sessions), do: nil

  defp session_id(_effective, method, sessions) do
    Map.fetch!(sessions, server_of(method))
  end

  defp sane_fields(method) do
    fields = %{
      "jsonrpc" => ~s("2.0"),
      "method" => ~s("#{method}"),
      "params" => params_raw(method)
    }

    if String.starts_with?(method, "notifications/") do
      fields
    else
      Map.put(fields, "id", "1")
    end
  end

  defp params_raw(method) do
    case method do
      "initialize" ->
        ~s({"protocolVersion":"2025-11-25","clientInfo":{"name":"fuzz","version":"1.0.0"}})

      "tools/call" ->
        ~s({"name":"get_date"})

      "prompts/get" ->
        ~s({"name":"code_review","arguments":{"language":"elixir"}})

      "resources/read" ->
        ~s({"uri":"file:///marketing.md"})

      "resources/subscribe" ->
        ~s({"uri":"file:///marketing.md"})

      "resources/unsubscribe" ->
        ~s({"uri":"file:///api_call.md"})

      "logging/setLevel" ->
        ~s({"level":"info"})

      "completion/complete" ->
        ~s({"ref":{"type":"ref/prompt","name":"code_review"},"argument":{"name":"language","value":"el"}})

      m when m in ["tasks/get", "tasks/cancel", "tasks/result"] ->
        ~s({"taskId":"missing-task"})

      "notifications/cancelled" ->
        ~s({"requestId":1,"reason":"fuzz"})

      _ ->
        "{}"
    end
  end

  defp encode_fields(fields) do
    json =
      fields
      |> Enum.map_join(",", fn {key, raw} -> ~s("#{key}":#{raw}) end)

    "{" <> json <> "}"
  end

  defp server_of(method) do
    {_method, server} = List.keyfind(@method_servers, method, 0)
    server
  end

  defp post_raw(body) do
    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
  end

  defp call_router(conn, server) do
    conn
    |> put_req_header("origin", @cors_origin)
    |> OzMcp.Router.call(OzMcp.Router.init(server: inst(server), allowed_origins: [@cors_origin]))
  end

  defp valid_error?(%{"code" => code, "message" => message})
       when is_integer(code) and is_binary(message),
       do: true

  defp valid_error?(_error), do: false
end
