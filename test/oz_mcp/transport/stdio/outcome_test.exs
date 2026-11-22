defmodule OzMcp.Transport.Stdio.OutcomeTest do
  use ExUnit.Case, async: true

  alias OzMcp.Context.Error
  alias OzMcp.Transport.Stdio.Outcome
  alias OzMcp.Utils.JsonRpc

  defp stop(result, code), do: {:stop, %{status: nil, result: result, error_code: code}}

  defp error_body(code, id), do: elem(Error.build(Error.new(code), id), 1)

  defp context(attrs) do
    Map.merge(
      %{
        error: nil,
        rpc_id: "id-1",
        rpc_method: "ping",
        rpc_response: nil,
        session_id: "session-1"
      },
      Map.new(attrs)
    )
  end

  describe "refusal/2" do
    test "a duplicate id gives the duplicate error line and an error span" do
      outcome = Outcome.refusal({:error, :duplicate}, "id-1")

      assert outcome == %Outcome{
               span: stop(:error, :rpc_duplicate_request_id),
               line: error_body(:rpc_duplicate_request_id, "id-1"),
               stop?: false,
               adopt: nil,
               next: nil
             }
    end

    test "a lost session stops the transport after the line" do
      outcome = Outcome.refusal({:error, :no_session}, "id-1")

      assert outcome.span == stop(:error, :http_invalid_session)
      assert outcome.line == error_body(:http_invalid_session, "id-1")
      assert outcome.stop? == true
    end

    test "any other registration failure gives the internal error" do
      outcome = Outcome.refusal({:error, :unavailable}, "id-1")

      assert outcome.span == stop(:error, :http_internal_error)
      assert outcome.line == error_body(:http_internal_error, "id-1")
      assert outcome.stop? == false
    end

    test "every refusal code exists in the error table" do
      codes = [:rpc_duplicate_request_id, :http_invalid_session, :http_internal_error]

      for code <- codes do
        assert code in Error.codes()
      end
    end
  end

  describe "validation/1" do
    test "a refused request gets the line of the error of the context" do
      outcome = Outcome.validation(context(error: Error.new(:rpc_method_not_found)))

      assert outcome.span == stop(:error, :rpc_method_not_found)
      assert outcome.line == error_body(:rpc_method_not_found, "id-1")
      assert outcome.stop? == false
    end

    test "the line keeps the data of the error of the context" do
      context = context(error: Error.new(:rpc_bad_arguments, %{"missing" => "count"}))
      outcome = Outcome.validation(context)

      assert outcome.line["error"]["data"] == %{"missing" => "count"}
    end

    test "a notification gets no line" do
      context =
        context(
          error: Error.new(:rpc_method_not_found),
          rpc_id: nil,
          rpc_method: "notifications/initialized"
        )

      outcome = Outcome.validation(context)

      assert outcome.line == nil
      assert outcome.span == stop(:error, :rpc_method_not_found)
    end

    test "an answer of the client gets no line" do
      context =
        context(
          error: Error.new(:rpc_method_not_found),
          rpc_response: %{"result" => %{}},
          rpc_kind: :response
        )

      outcome = Outcome.validation(context)

      assert outcome.line == nil
      assert outcome.span == stop(:error, :rpc_method_not_found)
    end

    test "a malformed answer of the client gets no line" do
      context =
        context(error: Error.new(:rpc_invalid_request), rpc_id: "srv-1", rpc_kind: :response)

      outcome = Outcome.validation(context)

      assert outcome.line == nil
      assert outcome.span == stop(:error, :rpc_invalid_request)
    end

    test "a message with no id that is not a notification gets a line" do
      outcome = Outcome.validation(context(error: Error.new(:rpc_method_not_found), rpc_id: nil))

      assert outcome.line == error_body(:rpc_method_not_found, nil)
    end

    test "a lost session on an open connection stops the transport" do
      outcome = Outcome.validation(context(error: Error.new(:http_invalid_session)))

      assert outcome.span == stop(:error, :http_invalid_session)
      assert outcome.stop? == true
    end

    test "a lost session before initialize does not stop the transport" do
      outcome =
        Outcome.validation(context(error: Error.new(:http_invalid_session), session_id: nil))

      assert outcome.stop? == false
    end

    test "another code on an open connection does not stop the transport" do
      outcome = Outcome.validation(context(error: Error.new(:rpc_method_not_found)))

      assert outcome.stop? == false
    end
  end

  describe "from_handler/2" do
    test "a success gives the response as the line and an ok span" do
      outcome = Outcome.from_handler({:rpc_success, %{"result" => "ok"}}, "id-1")

      assert outcome == %Outcome{
               span: stop(:ok, nil),
               line: %{"result" => "ok"},
               stop?: false,
               adopt: nil,
               next: nil
             }
    end

    test "a handler error gives the response as the line and an rpc_error span" do
      response = JsonRpc.error("id-1", -32601, "method not found")
      outcome = Outcome.from_handler({:rpc_error, response}, "id-1")

      assert outcome.span == stop(:rpc_error, nil)
      assert outcome.line == response
    end

    test "a notification gets an ok span and no line" do
      outcome = Outcome.from_handler(:notified, nil)

      assert outcome == %Outcome{span: stop(:ok, nil), line: nil}
    end

    test "an internal error of a notification gets no line" do
      outcome = Outcome.from_handler(:internal_error, nil)

      assert outcome == %Outcome{span: stop(:error, :http_internal_error), line: nil}
    end

    test "an internal error of a request gets the error of the table" do
      outcome = Outcome.from_handler(:internal_error, "id-1")

      assert outcome.span == stop(:error, :http_internal_error)
      assert outcome.line["error"]["code"] == -32603
      assert outcome.line["error"]["message"] == "internal server error"
    end

    test "a created session carries the id that the transport must adopt" do
      outcome = Outcome.from_handler({:session_created, "session-9", %{"result" => %{}}}, "id-1")

      assert outcome == %Outcome{
               span: stop(:ok, nil),
               line: %{"result" => %{}},
               adopt: "session-9"
             }
    end

    test "a refused session gives the error of the table" do
      outcome = Outcome.from_handler({:refused, :too_many_sessions}, "id-1")

      assert outcome.span == stop(:error, :http_too_many_sessions)
      assert outcome.line == error_body(:http_too_many_sessions, "id-1")
    end

    test "every code of the handler outcomes exists in the error table" do
      codes = [:http_internal_error, :http_too_many_sessions]

      for code <- codes do
        assert code in Error.codes()
      end
    end
  end

  describe "crashed/3" do
    test "the inline path gives an exception event and the crash line" do
      stacktrace = [{TestModule, :fun, 0, []}]
      outcome = Outcome.crashed(:inline, "id-1", {:error, :boom, stacktrace})

      assert outcome.span == {:exception, :error, :boom, stacktrace}
      assert outcome.line == JsonRpc.error("id-1", -32603, "internal error")
    end

    test "the child path gives an error stop and the crash line" do
      outcome = Outcome.crashed(:child, "id-1", {:error, :boom, []})

      assert outcome.span == stop(:error, nil)
      assert outcome.line == JsonRpc.error("id-1", -32603, "internal error")
    end

    test "the crash line keeps its own text" do
      outcome = Outcome.crashed(:child, "id-1", {:error, :boom, []})

      assert outcome.line["error"]["code"] == -32603
      assert outcome.line["error"]["message"] == "internal error"
    end
  end
end
