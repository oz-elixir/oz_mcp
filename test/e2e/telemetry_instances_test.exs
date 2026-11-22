#
# The events of many instances in one application, over a real
# connection. One handler on the default prefix gets the name of the
# instance and of the server module of each request, two instances of
# one server module differ in the instance only, a handler that is
# attached to one prefix takes no event of the instance with the other
# prefix and a bad prefix stops the boot. The stability test causes
# every event that the suite can produce — the spans, the refusals of
# the authentication, a limit, the restore of a session, the writes of
# the snapshot store and the end of the sessions of a principal — and
# checks the metadata of each one against the catalog: the keys, the
# events that know the transport and the absence of any value that
# holds data of a caller.
#
defmodule OzMcp.E2E.TelemetryInstancesTest do
  use ExUnit.Case, async: true

  alias OzMcp.E2E.Client
  alias OzMcp.Sessions
  alias Support.Helpers.PersistentSnapshot
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  @moduletag :e2e

  @server OzMcp.E2E.Server
  @other_server Servers.Default
  @outbound_server Servers.Outbound
  @authorized_server Servers.Authorized

  @accept "application/json, text/event-stream"

  # The tails of the events that the corpus of the stability test causes.
  # An event that the library adds without an update of this list and of
  # the catalog fails the stability test.
  #
  @expected_tails [
    [:request, :start],
    [:request, :stop],
    [:callback, :start],
    [:callback, :stop],
    [:session, :start],
    [:session, :stop],
    [:session, :restore],
    [:task, :start],
    [:task, :stop],
    [:client_request, :start],
    [:client_request, :stop],
    [:auth, :refused],
    [:limit, :reached],
    [:snapshot, :write],
    [:principal, :revoked]
  ]

  # The keys of the metadata of each event, next to `instance` and
  # `server` that every event carries.
  #
  @catalog %{
    [:request, :start] => [:transport, :method, :kind],
    [:request, :stop] => [:transport, :method, :kind, :result, :status, :error_code],
    [:request, :exception] => [:transport, :method, :kind, :exception_kind, :reason, :stacktrace],
    [:callback, :start] => [:method, :name],
    [:callback, :stop] => [:method, :name, :result, :error_code],
    [:callback, :exception] => [:method, :name, :exception_kind, :reason, :stacktrace],
    [:session, :start] => [:transport, :restored?],
    [:session, :stop] => [:transport, :restored?, :reason],
    [:session, :restore] => [:outcome],
    [:task, :start] => [],
    [:task, :stop] => [:status],
    [:client_request, :start] => [:method],
    [:client_request, :stop] => [:method, :result],
    [:client_request, :exception] => [:method, :exception_kind, :reason, :stacktrace],
    [:auth, :refused] => [:stage, :reason],
    [:limit, :reached] => [:limit, :limit_value, :scope, :outcome],
    [:snapshot, :write] => [:action, :result],
    [:principal, :revoked] => []
  }

  # The events whose metadata carries the transport. The request span
  # always knows the transport of the message. The session span carries
  # it when the caller declared one: a session that the host starts by
  # hand with no transport gives no key. The other events know no
  # transport or have only one.
  #
  @transport_required_tails [
    [:request, :start],
    [:request, :stop],
    [:request, :exception]
  ]

  @transport_allowed_tails @transport_required_tails ++ [[:session, :start], [:session, :stop]]

  test "one handler for the default prefix gets the instance and the server of each request" do
    ref = TelemetryCapture.attach()

    a = start_instance!(@server, [])
    b = start_instance!(@other_server, [])

    {_client, {200, _headers, _body}} = Client.new(start_endpoint!(a)) |> Client.initialize()
    {_client, {200, _headers, _body}} = Client.new(start_endpoint!(b)) |> Client.initialize()

    events_a = drain_all(ref, a)
    events_b = drain_all(ref, b)

    refute events_a == []
    refute events_b == []

    for {name, _measurements, meta} <- events_a do
      assert hd(name) == :oz_mcp
      assert meta.instance == a
      assert meta.server == @server
    end

    for {_name, _measurements, meta} <- events_b do
      assert meta.instance == b
      assert meta.server == @other_server
    end

    assert [%{method: "initialize", kind: :request, transport: :http_streamable}] =
             metas(events_a, [:request, :stop])

    assert [%{method: "initialize", kind: :request, transport: :http_streamable}] =
             metas(events_b, [:request, :stop])
  end

  test "two names of one server module differ in the instance and share the server" do
    ref = TelemetryCapture.attach()

    a = start_instance!(@server, [])
    b = start_instance!(@server, [])
    assert a != b

    {_client, {200, _headers, _body}} = Client.new(start_endpoint!(a)) |> Client.initialize()
    {_client, {200, _headers, _body}} = Client.new(start_endpoint!(b)) |> Client.initialize()

    events_a = drain_all(ref, a)
    events_b = drain_all(ref, b)

    assert [%{method: "initialize"}] = metas(events_a, [:request, :stop])
    assert [%{method: "initialize"}] = metas(events_b, [:request, :stop])

    assert events_a |> Enum.map(&elem(&1, 2).instance) |> MapSet.new() == MapSet.new([a])
    assert events_b |> Enum.map(&elem(&1, 2).instance) |> MapSet.new() == MapSet.new([b])

    assert (events_a ++ events_b) |> Enum.map(&elem(&1, 2).server) |> MapSet.new() ==
             MapSet.new([@server])
  end

  test "a handler on one prefix takes no event of the instance with the other prefix" do
    prefix_a = [:oz_mcp, :multi_a]
    prefix_b = [:oz_mcp, :multi_b]

    ref = TelemetryCapture.attach(prefix_a)

    a = start_instance!(@server, telemetry_prefix: prefix_a)
    b = start_instance!(@server, telemetry_prefix: prefix_b)

    url_a = start_endpoint!(a)
    url_b = start_endpoint!(b)

    {_client, {200, _headers, _body}} = Client.new(url_a) |> Client.initialize()
    {_client, {200, _headers, _body}} = Client.new(url_b) |> Client.initialize()

    events_a = drain_all(ref, a, prefix_a)

    assert [%{method: "initialize"}] = metas(events_a, [:request, :stop], prefix_a)
    assert [] = TelemetryCapture.drain(ref, b)
  end

  for bad <- [[], "oz_mcp", [:oz_mcp, "x"], nil] do
    test "a bad telemetry_prefix stops the boot: #{inspect(bad)}" do
      bad = unquote(bad)
      name = Module.concat(@server, "T#{System.unique_integer([:positive])}")

      spec = {OzMcp, server: @server, name: name, allowed_origins: [], telemetry_prefix: bad}

      assert_raise ArgumentError,
                   ~r/telemetry_prefix must be a non-empty list of atoms/,
                   fn -> start_supervised!(spec, id: :refused_boot) end

      assert :not_running = OzMcp.Instance.config(name)
    end
  end

  test "the metadata of every event of the suite stays in the catalog" do
    ref = TelemetryCapture.attach()

    main = start_instance!(@server, max_sessions: 1, session_snapshot: PersistentSnapshot)
    out = start_instance!(@outbound_server, [])
    auth = start_instance!(@authorized_server, resource_url: "https://mcp.example.com/mcp")

    url_main = start_endpoint!(main)
    url_out = start_endpoint!(out)
    url_auth = start_endpoint!(auth)

    Support.Entities.Tools.TaskSlowTest.use_instance(main)

    # One request, one callback that answers, one callback that refuses,
    # a method that the server does not serve, a notification and a body
    # that is not a JSON-RPC message.
    #
    client = url_main |> Client.new() |> Client.ready!()

    {_client, {200, _headers, %{"result" => %{}}}} = Client.request(client, "ping")

    # The restore of a session that a crash left in the snapshot store:
    # the write of the snapshots and the read of the store give their
    # events and the restore starts the session again.
    #
    assert wait_snapshot(main, client.session_id)

    {:ok, session_pid} = OzMcp.Instance.whereis(main, {:session, client.session_id})
    down_ref = Process.monitor(session_pid)
    Process.exit(session_pid, :kill)
    assert_receive {:DOWN, ^down_ref, :process, ^session_pid, :killed}
    assert wait_session_gone(main, client.session_id)

    {_client, {200, _headers, %{"result" => %{}}}} = Client.request(client, "ping")

    {_client, {200, _headers, %{"result" => %{}}}} =
      Client.request(client, "tools/call", %{
        "name" => "get_temperature",
        "arguments" => %{"location" => "Paris"}
      })

    {_client, {200, _headers, %{"error" => %{"code" => -32601}}}} =
      Client.request(client, "tools/call", %{"name" => "gamma_1"})

    {_client, {200, _headers, %{"error" => %{"code" => -32601}}}} =
      Client.request(client, "no/such_method")

    {_client, {202, _headers, nil}} =
      Client.notify(client, "notifications/roots/list_changed")

    {_client, {400, _headers, _body}} =
      Client.send_raw(client, :post, ~s([{"jsonrpc":"2.0","id":1,"method":"ping"}]),
        with_defaults: false,
        headers: [{"content-type", "application/json"}, {"accept", @accept}]
      )

    # A task: the span of the task covers its callback. The finish goes to
    # the runner of this instance: the call waits for a runner of its own,
    # the runner of a test that ran before can still be there.
    #
    previous = Support.Entities.Tools.TaskSlowTest.last_runner_pid()

    {client, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
      Client.request(client, "tools/call", %{"name" => "task_slow", "task" => %{}})

    Support.Entities.Tools.TaskSlowTest.await_runner(previous)
    Support.Entities.Tools.TaskSlowTest.finish()
    {_client, %{"status" => "completed"}} = poll_status(client, task_id, "completed")

    # A start over the limit of the sessions: the limit event. The live
    # stream holds the only slot, so the start is refused.
    #
    {_response, _sse} = Client.open_get(client)

    {_other, {429, _headers, %{"error" => %{"code" => -32000}}}} =
      Client.initialize(Client.new(url_main))

    # The end of the session: the reason of the end.
    #
    {_client, {200, _headers, nil}} = Client.delete(client)

    # A request of the server to the client and the answer of the client
    # that carries a JSON-RPC response for its id.
    #
    out_client = url_out |> Client.new() |> Client.ready!()

    {out_client, resp, sse} =
      Client.stream_request(out_client, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"method" => "ping", "timeout" => 10_000}
      })

    {:ok, event, sse} = Client.next_event(resp, sse)
    request = JSON.decode!(event.data)
    assert %{"method" => "ping", "id" => _id} = request

    {_out_client, {202, _headers, nil}} = Client.answer(out_client, request, %{})
    {:ok, _answer_event, _sse} = Client.next_event(resp, sse)
    {:ended, _sse} = Client.next_frame(resp, sse)

    # A refusal of the authentication: the token of this request never
    # comes back in any value of the metadata.
    #
    secret = "stability-secret-token-#{System.unique_integer([:positive])}"

    {_client, {401, _headers, _body}} =
      Client.new(url_auth, [{"authorization", "Bearer " <> secret}]) |> Client.initialize()

    # The end of every session of a principal: the revocation event,
    # with the count of the sessions that the call ended.
    #
    revoked = {"https://issuer.test", "stability-revoked-user"}
    {:ok, _first} = Sessions.start(auth, principal_key: revoked)
    {:ok, _second} = Sessions.start(auth, principal_key: revoked)

    assert {:ok, ended} = Sessions.terminate_principal(auth, revoked)
    assert length(ended) == 2

    events = collect_events(ref, [main, out, auth])
    events = events ++ Enum.flat_map([main, out, auth], &TelemetryCapture.drain(ref, &1))

    tails = Enum.map(events, fn {name, _, _} -> tl(name) end)

    assert MapSet.new(tails) == MapSet.new(@expected_tails),
           "the events of the corpus: #{inspect(Enum.frequencies(tails))}"

    for ev <- events do
      check_catalog(ev, [main, out, auth], secret)
    end
  end

  # -------------------------------------------------------------------
  # The boot of the instances and the endpoints
  # -------------------------------------------------------------------

  # The write of a snapshot runs in the writer of the instance, after
  # the change of the session: the test waits for the store.
  #
  defp wait_snapshot(instance, session_id) do
    if Utils.eventually(fn -> PersistentSnapshot.get(instance, session_id) != nil end) do
      :ok
    else
      flunk("the snapshot never reached the store")
    end
  end

  # The Registry removes the entry of a process that died: the test
  # waits for the removal, so the next request takes the restore path.
  #
  defp wait_session_gone(instance, session_id) do
    if Utils.eventually(fn ->
         Sessions.lookup(instance, session_id) == {:error, :no_session}
       end) do
      :ok
    else
      flunk("the session never left the registry")
    end
  end

  defp start_instance!(server, opts) do
    name = Module.concat(server, "T#{System.unique_integer([:positive])}")

    Utils.start_instance(
      server,
      [name: name, allowed_origins: ["http://localhost"]] ++ opts
    )

    name
  end

  defp start_endpoint!(instance) do
    kind = OzMcp.E2E.HttpServer.kind(%{})

    {spec, port_fun} =
      OzMcp.E2E.HttpServer.child(kind, {OzMcp.E2E.Router, instance: instance})

    listener = start_supervised!(spec, id: {:listener, instance})
    port = port_fun.(listener)
    "http://127.0.0.1:#{port}/mcp"
  end

  # -------------------------------------------------------------------
  # The collection of the events
  # -------------------------------------------------------------------

  defp named(events, tail, prefix),
    do: Enum.filter(events, fn {name, _, _} -> Enum.drop(name, length(prefix)) == tail end)

  defp metas(events, tail, prefix \\ [:oz_mcp]),
    do: events |> named(tail, prefix) |> Enum.map(&elem(&1, 2))

  # The events of the instance that are in the mailbox and the ones that
  # still arrive while the span of the last request closes: the stop of a
  # request span runs right after the answer went out.
  #
  defp drain_all(ref, instance, prefix \\ [:oz_mcp], acc \\ [], waits \\ 100)

  defp drain_all(_ref, _instance, _prefix, acc, 0), do: acc

  defp drain_all(ref, instance, prefix, acc, waits) do
    fresh = TelemetryCapture.drain(ref, instance)
    acc = acc ++ fresh

    cond do
      fresh != [] ->
        drain_all(ref, instance, prefix, acc, waits - 1)

      metas(acc, [:request, :stop], prefix) != [] ->
        acc

      true ->
        case TelemetryCapture.drain_wait(ref, instance, 100) do
          [] -> drain_all(ref, instance, prefix, acc, waits - 1)
          events -> drain_all(ref, instance, prefix, acc ++ events, waits - 1)
        end
    end
  end

  defp collect_events(ref, instances, acc \\ [], tries \\ 200)

  defp collect_events(_ref, _instances, acc, 0), do: acc

  defp collect_events(ref, instances, acc, tries) do
    fresh = Enum.flat_map(instances, &TelemetryCapture.drain(ref, &1))

    cond do
      fresh != [] ->
        collect_events(ref, instances, acc ++ fresh, tries - 1)

      tails_seen?(acc) ->
        acc

      true ->
        #
        # The wait is for the next telemetry event, not for a fixed time.
        #
        receive do
          {event, ^ref, measurements, %{instance: instance} = meta} ->
            if instance in instances do
              collect_events(ref, instances, acc ++ [{event, measurements, meta}], tries - 1)
            else
              collect_events(ref, instances, acc, tries - 1)
            end
        after
          100 -> collect_events(ref, instances, acc, tries - 1)
        end
    end
  end

  defp tails_seen?(events) do
    MapSet.new(Enum.map(events, fn {name, _, _} -> tl(name) end)) == MapSet.new(@expected_tails)
  end

  # -------------------------------------------------------------------
  # The checks of the catalog
  # -------------------------------------------------------------------

  defp check_catalog({name, _measurements, meta}, instances, secret) do
    tail = tl(name)
    allowed = allowed_keys(tail)

    extra =
      meta |> Map.keys() |> MapSet.new() |> MapSet.difference(allowed)

    assert extra == MapSet.new(),
           "the metadata of #{inspect(name)} holds keys outside of the catalog: " <>
             inspect(MapSet.to_list(extra))

    assert meta.instance in instances,
           "the metadata of #{inspect(name)} names a foreign instance: #{inspect(meta.instance)}"

    assert is_atom(meta.server)

    cond do
      tail in @transport_required_tails ->
        assert Map.has_key?(meta, :transport), "no transport in the metadata of #{inspect(name)}"

      tail in @transport_allowed_tails ->
        :ok

      true ->
        refute Map.has_key?(meta, :transport), "a transport in the metadata of #{inspect(name)}"
    end

    # An exception event carries the reason and the stacktrace of a defect
    # of the library itself: it takes no check of the values.
    #
    unless :exception in tail do
      assert no_caller_data?(meta),
             "the metadata of #{inspect(name)} holds data of a caller: #{inspect(meta)}"

      refute holds?(meta, secret),
             "the metadata of #{inspect(name)} holds the refused token: #{inspect(meta)}"
    end
  end

  defp allowed_keys(tail) do
    keys = MapSet.new([:instance, :server | Map.fetch!(@catalog, tail)])

    if span?(tail), do: MapSet.put(keys, :telemetry_span_context), else: keys
  end

  defp span?(tail), do: tl(tail) in [[:start], [:stop], [:exception]]

  # No value of the metadata is a conn, a principal, a long binary, or a
  # map or list that holds one.
  #
  defp no_caller_data?(meta) do
    Enum.all?(meta, fn
      {_key, %Plug.Conn{}} -> false
      {_key, %OzMcp.Auth.Principal{}} -> false
      {_key, value} -> no_long_binary?(value)
    end)
  end

  defp no_long_binary?(value) when is_binary(value), do: byte_size(value) <= 200

  defp no_long_binary?(value) when is_map(value),
    do: Enum.all?(value, fn {key, inner} -> no_long_binary?(key) and no_long_binary?(inner) end)

  defp no_long_binary?(value) when is_list(value), do: Enum.all?(value, &no_long_binary?/1)
  defp no_long_binary?(_value), do: true

  defp holds?(value, secret) when is_binary(value), do: String.contains?(value, secret)

  defp holds?(value, secret) when is_map(value) do
    if is_struct(value) do
      value |> Map.from_struct() |> holds?(secret)
    else
      Enum.any?(value, fn {key, inner} -> holds?(key, secret) or holds?(inner, secret) end)
    end
  end

  defp holds?(value, secret) when is_list(value), do: Enum.any?(value, &holds?(&1, secret))

  defp holds?(value, secret) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&holds?(&1, secret))

  defp holds?(_value, _secret), do: false

  # -------------------------------------------------------------------
  # The wait of a task
  # -------------------------------------------------------------------

  defp poll_status(client, task_id, wanted) do
    assert Utils.eventually(fn ->
             match?(
               {_client, {200, _headers, %{"result" => %{"status" => ^wanted}}}},
               Client.request(client, "tasks/get", %{"taskId" => task_id})
             )
           end)

    {_client, {200, _headers, %{"result" => task}}} =
      Client.request(client, "tasks/get", %{"taskId" => task_id})

    {client, task}
  end
end
