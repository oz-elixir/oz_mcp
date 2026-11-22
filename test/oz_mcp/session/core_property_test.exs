defmodule OzMcp.Session.CorePropertyTest do
  use ExUnit.Case, async: true

  use ExUnitProperties

  alias OzMcp.Session.{Core, EventLog, Roots, View}
  alias OzMcp.Session.Snapshot.None

  @max_runs 50

  @roots_operations [
    :changed,
    :started,
    :down,
    :start_failed,
    :deadline,
    :stop
  ]

  defmodule Counter do
    @spec get_stream_id() :: String.t()
    def get_stream_id, do: "g." <> Integer.to_string(next(:get_stream_id))

    @spec request_id() :: String.t()
    def request_id, do: "s" <> Integer.to_string(next(:request_id))

    defp next(key) do
      n = Process.get(key, 0) + 1
      Process.put(key, n)
      n
    end
  end

  defmodule Model do
    alias OzMcp.Session.{Core, EventLog, Roots, View}
    alias OzMcp.Session.CorePropertyTest.Counter
    alias OzMcp.Session.Snapshot.None

    @max_length 60
    @max_chunks 30

    @single [
      :open_request,
      :open_request_stream,
      :emit_request,
      :emit_stream,
      :emit_session,
      :close_request,
      :end_request,
      :open_get,
      :close_get,
      :take_over,
      :request_client,
      :deliver
    ]

    @chunks [
      [:open_request_stream],
      [:open_request_stream, :take_over],
      [:open_request_stream, :take_over, :emit_stream],
      [:open_request_stream, :emit_stream, :take_over, :emit_stream],
      [:open_request_stream, :take_over, :emit_request, :emit_stream]
    ]

    defstruct core: nil,
              tags: MapSet.new(),
              tag_pids: %{},
              sent: [],
              emits: [],
              ordered: [],
              pending_client: %{},
              takeovers: [],
              finish_count: 0

    @type t :: %__MODULE__{}

    @spec operations() :: StreamData.t([term()])
    def operations do
      frequency([
        {6, map(member_of(@single), &[&1])},
        {1, map(non_negative_integer(), &[{:down, &1}])},
        {3, member_of(@chunks)}
      ])
      |> list_of(max_length: @max_chunks)
      |> map(&(&1 |> List.flatten() |> Enum.take(@max_length)))
    end

    @spec run([term()]) :: t()
    def run(operations) do
      model = %__MODULE__{core: new_core()}

      Enum.reduce(operations, model, &apply_operation/2)
    end

    @spec new_core() :: Core.t()
    def new_core do
      Process.delete(:get_stream_id)
      Process.delete(:request_id)

      %Core{
        instance: __MODULE__,
        id: "session",
        pid: self(),
        ids: Counter,
        view: %View{initialized: true, pid: self()},
        opts: %{
          session_timeout_ms: 30_000,
          request_timeout_ms: 5_000,
          request_cancel_grace_ms: 100,
          sse_resume_window_ms: 10_000,
          max_streams_per_session: nil,
          session_snapshot: None,
          tasks_follow_session: false
        },
        log: EventLog.new(100_000, 100_000_000, 100_000_000, 1_000)
      }
    end

    @spec new_roots_core() :: Core.t()
    def new_roots_core do
      %Core{
        instance: __MODULE__,
        id: "session",
        opts: %{request_timeout_ms: 1_000, request_cancel_grace_ms: 10}
      }
    end

    @spec run_roots(atom(), Core.t()) :: {Core.t(), [OzMcp.Session.Effect.t()]}
    def run_roots(:changed, core),
      do: Roots.changed(core, %{server: __MODULE__, session_id: "session"})

    def run_roots(:started, core), do: Roots.started(core, self())
    def run_roots(:down, core), do: Roots.down(core)
    def run_roots(:start_failed, core), do: Roots.start_failed(core, :not_running)
    def run_roots(:deadline, core), do: Roots.deadline(core, self())
    def run_roots(:stop, core), do: Roots.stop(core)

    @spec end_all(t()) :: t()
    def end_all(model) do
      model
      |> drop_streams()
      |> end_requests()
      |> end_outbound()
    end

    @spec close_requests(t()) :: t()
    def close_requests(model) do
      model = Enum.reduce(request_ids(model), model, &close_request/2)
      drop_orphan_streams(model)
    end

    defp request_ids(model),
      do: model.core.requests |> Map.keys() |> Enum.sort()

    defp close_request(request_id, model) do
      case Map.get(model.core.requests, request_id) do
        %{stream_id: stream_id} when is_binary(stream_id) ->
          apply_event(
            model,
            {:call, {:close_request, request_id, stream_id, {:response, "done", false}}}
          )

        _no_stream_or_gone ->
          apply_event(model, {:cast, {:end_request, request_id}})
      end
    end

    # A request that died with its owner left its stream entry behind: the
    # DOWN of the owner is what drops it, not the close of the request.
    #
    defp drop_orphan_streams(model) do
      model.core.streams
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reduce(model, fn stream_id, model ->
        entry = Map.fetch!(model.core.streams, stream_id)

        if Map.has_key?(model.core.requests, entry.request_id) do
          model
        else
          pid = Map.fetch!(model.tag_pids, {:owner, stream_id})
          apply_event(model, {:down, {:owner, stream_id}, pid})
        end
      end)
    end

    @spec event_numbers(t()) :: [{String.t(), [String.t()]}]
    def event_numbers(model) do
      model.sent
      |> Enum.reject(fn {_stream_id, event_id, _message, _to} -> is_nil(event_id) end)
      |> Enum.group_by(
        fn {stream_id, _event_id, _message, _to} -> stream_id end,
        fn {_stream_id, event_id, _message, _to} -> event_id end
      )
      |> Enum.to_list()
    end

    @spec tags(t()) :: MapSet.t()
    def tags(model), do: model.tags

    @spec tag_pids(t()) :: %{term() => pid()}
    def tag_pids(model), do: model.tag_pids

    @spec takeovers(t()) :: [map()]
    def takeovers(model), do: model.takeovers

    @spec ordered(t()) :: [{String.t(), String.t()}]
    def ordered(model), do: model.ordered

    @spec expected_tags(Core.t()) :: MapSet.t()
    def expected_tags(core) do
      requests =
        for {request_id, _request} <- core.requests, do: {:request, request_id}

      outbound =
        for {out_id, _entry} <- core.outbound, do: {:outbound, out_id}

      posts =
        Enum.flat_map(core.streams, fn {stream_id, entry} ->
          #
          # A stream whose owner is gone (a hand-off) has no owner monitor.
          #
          owner = if is_pid(entry.owner), do: [{:owner, stream_id}], else: []
          resumer = if is_pid(entry.resumer), do: [{:resumer, stream_id}], else: []
          owner ++ resumer
        end)

      gets = for %{id: stream_id} <- core.get_streams, do: {:get, stream_id}

      MapSet.new(requests ++ outbound ++ posts ++ gets)
    end

    @spec replay_ids(map()) :: [String.t()]
    def replay_ids(takeover), do: takeover.replay

    @spec live_events(t(), map()) :: [%{event_id: String.t(), to: pid()}]
    def live_events(model, takeover) do
      sent_end = takeover.sent_end || length(model.sent)

      model.sent
      |> Enum.slice(takeover.sent_start, sent_end - takeover.sent_start)
      |> Enum.filter(fn {stream_id, _event_id, _message, _to} ->
        stream_id == takeover.stream_id
      end)
      |> Enum.map(fn {_stream_id, event_id, _message, to} -> %{event_id: event_id, to: to} end)
    end

    @spec log_ids(t(), map()) :: [String.t()]
    def log_ids(model, takeover) do
      takeover.log ||
        model.core.log |> EventLog.events(takeover.stream_id) |> Enum.map(&elem(&1, 0))
    end

    @spec resumer_streams(t()) :: [String.t()]
    def resumer_streams(model) do
      model.tags
      |> Enum.filter(&match?({:resumer, _}, &1))
      |> Enum.map(&elem(&1, 1))
      |> Enum.sort()
    end

    @spec resumer_down_and_emit(t(), String.t()) :: {t(), pid(), tuple() | nil}
    def resumer_down_and_emit(model, stream_id) do
      pid = Map.fetch!(model.tag_pids, {:resumer, stream_id})
      owner = Map.fetch!(model.core.streams, stream_id).owner
      model = apply_event(model, {:down, {:resumer, stream_id}, pid})
      model = apply_event(model, {:cast, {:emit, {:stream, stream_id}, "after the resumer"}})

      {model, owner, List.last(model.sent)}
    end

    defp apply_operation(operation, model) do
      case event_for(operation, model) do
        :skip ->
          model

        {event, meta} ->
          {model, effects} = handle(event, model)
          model = apply_meta(model, meta)
          record_operation(operation, meta, effects, model)
      end
    end

    defp handle(event, model) do
      model = remove_down_tag(model, event)
      {core, effects} = Core.handle(event, :ready, model.core)
      model = %{model | core: core}
      model = run_effects(effects, model)

      {close_takeovers(model), effects}
    end

    defp apply_event(model, event) do
      {model, _effects} = handle(event, model)
      model
    end

    defp drop_streams(model) do
      model.core.streams
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reduce(model, fn stream_id, model ->
        pid = Map.fetch!(model.tag_pids, {:owner, stream_id})
        apply_event(model, {:down, {:owner, stream_id}, pid})
      end)
    end

    defp end_requests(model) do
      model.core.requests
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reduce(model, fn request_id, model ->
        apply_event(model, {:cast, {:end_request, request_id}})
      end)
    end

    defp end_outbound(model) do
      model.core.outbound
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reduce(model, fn out_id, model ->
        pid = Map.fetch!(model.tag_pids, {:outbound, out_id})
        apply_event(model, {:down, {:outbound, out_id}, pid})
      end)
    end

    defp event_for(:open_request, _model) do
      request_id = Counter.request_id()
      {{:call, {:open_request, request_id, spawn_pid(), nil}}, %{}}
    end

    defp event_for(:open_request_stream, _model) do
      request_id = Counter.request_id()
      stream_id = Counter.request_id()
      {{:call, {:open_request, request_id, spawn_pid(), {stream_id, :sse}}}, %{}}
    end

    defp event_for(:emit_request, model) do
      case first_request_id(model.core) do
        nil ->
          :skip

        request_id ->
          live = emit_request_live?(model.core, request_id)

          {{:cast, {:emit, {:request, request_id}, "message"}},
           %{live: live, request_id: request_id}}
      end
    end

    defp event_for(:emit_stream, model) do
      case first_stream_id(model.core) do
        nil -> :skip
        stream_id -> {{:cast, {:emit, {:stream, stream_id}, "message"}}, %{live: true}}
      end
    end

    defp event_for(:emit_session, model) do
      live = model.core.view.initialized and model.core.get_streams != []
      {{:cast, {:emit, :session, "message"}}, %{live: live}}
    end

    defp event_for(:close_request, model) do
      case first_request(model.core, &is_binary(&1.stream_id)) do
        nil ->
          :skip

        {request_id, request} ->
          started? = rem(model.finish_count, 2) == 0

          {{:call,
            {:close_request, request_id, request.stream_id, {:response, "done", started?}}},
           %{finish_count: model.finish_count + 1}}
      end
    end

    defp event_for(:end_request, model) do
      case first_request_id(model.core) do
        nil -> :skip
        request_id -> {{:cast, {:end_request, request_id}}, %{}}
      end
    end

    defp event_for(:open_get, _model),
      do: {{:call, {:open_stream, :get, spawn_pid(), nil}}, %{}}

    defp event_for(:close_get, model) do
      pid =
        case Enum.find(sorted_tags(model), &match?({:get, _}, &1)) do
          nil -> spawn_pid()
          tag -> Map.fetch!(model.tag_pids, tag)
        end

      {{:call, {:close_stream, pid}}, %{}}
    end

    defp event_for({:down, n}, model) do
      case sorted_tags(model) do
        [] ->
          :skip

        tags ->
          tag = Enum.at(tags, rem(n, length(tags)))
          {{:down, tag, Map.fetch!(model.tag_pids, tag)}, %{}}
      end
    end

    defp event_for(:take_over, model) do
      case first_stream_id(model.core) do
        nil ->
          :skip

        stream_id ->
          last_event_id = stream_id <> ":0"
          {{:call, {:open_stream, :get, spawn_pid(), last_event_id}}, %{}}
      end
    end

    defp event_for(:request_client, model) do
      case first_request_id(model.core) do
        nil ->
          :skip

        request_id ->
          {{:call,
            {:request_client, spawn_pid(), {:request, request_id}, "method", %{"value" => 1}}},
           %{request_id: request_id}}
      end
    end

    defp event_for(:deliver, model) do
      case first_outbound_id(model.core) do
        nil -> :skip
        out_id -> {{:cast, {:deliver_outbound, out_id, {:ok, %{}}}}, %{}}
      end
    end

    defp first_request(core, predicate) do
      core.requests
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.find(fn {_request_id, request} -> predicate.(request) end)
    end

    defp first_request_id(core) do
      core.requests |> Map.keys() |> Enum.sort() |> List.first()
    end

    defp first_stream_id(core) do
      core.streams |> Map.keys() |> Enum.sort() |> List.first()
    end

    defp first_outbound_id(core) do
      core.outbound |> Map.keys() |> Enum.sort() |> List.first()
    end

    defp emit_request_live?(core, request_id) do
      case Map.get(core.requests, request_id) do
        %{stream_id: stream_id} when is_binary(stream_id) ->
          Map.has_key?(core.streams, stream_id)

        _no_stream ->
          false
      end
    end

    defp sorted_tags(model), do: model.tags |> MapSet.to_list() |> Enum.sort()

    defp spawn_pid, do: spawn(fn -> :ok end)

    defp apply_meta(model, %{finish_count: count}), do: %{model | finish_count: count}
    defp apply_meta(model, _meta), do: model

    defp record_operation(:request_client, meta, effects, model) do
      case sent_events(effects) do
        [{stream_id, event_id} | _rest] ->
          %{
            model
            | pending_client:
                Map.put(model.pending_client, meta.request_id, {stream_id, event_id})
          }

        [] ->
          model
      end
    end

    defp record_operation(:emit_request, meta, effects, model) do
      model = record_emit_order(meta, effects, model)
      record_emits(meta, effects, model)
    end

    defp record_operation(operation, meta, effects, model)
         when operation in [:emit_stream, :emit_session] do
      record_emits(meta, effects, model)
    end

    defp record_operation(_operation, _meta, _effects, model), do: model

    defp record_emits(meta, effects, model) do
      count = Enum.count(effects, &match?({:send, _, {:oz_mcp_stream, _, {:event, _, _}}}, &1))
      %{model | emits: [%{live: meta.live, count: count} | model.emits]}
    end

    defp record_emit_order(meta, effects, model) do
      with {stream_id, client_id} <- Map.get(model.pending_client, meta.request_id),
           [{^stream_id, emit_id} | _rest] <- sent_events(effects) do
        %{model | ordered: [{client_id, emit_id} | model.ordered]}
      else
        _other -> model
      end
    end

    defp sent_events(effects) do
      for {:send, _pid, {:oz_mcp_stream, stream_id, {:event, event_id, _message}}} <- effects,
          do: {stream_id, event_id}
    end

    defp remove_down_tag(model, {:down, tag, _pid}) do
      %{
        model
        | tags: MapSet.delete(model.tags, tag),
          tag_pids: Map.delete(model.tag_pids, tag)
      }
    end

    defp remove_down_tag(model, _event), do: model

    defp run_effects(effects, model) do
      Enum.reduce(effects, model, fn effect, model ->
        case effect do
          {:monitor, pid, tag} ->
            %{
              model
              | tags: MapSet.put(model.tags, tag),
                tag_pids: Map.put(model.tag_pids, tag, pid)
            }

          {:demonitor, tag} ->
            %{
              model
              | tags: MapSet.delete(model.tags, tag),
                tag_pids: Map.delete(model.tag_pids, tag)
            }

          {:send, pid, {:oz_mcp_stream, stream_id, {:event, event_id, message}}} ->
            %{model | sent: model.sent ++ [{stream_id, event_id, message, pid}]}

          {:send, _pid, _message} ->
            model

          {:reply, reply} ->
            record_reply(model, reply)

          _other ->
            model
        end
      end)
    end

    defp record_reply(model, {:ok, %{mode: :resume, stream_id: stream_id, replay: replay}}) do
      case Map.get(model.core.streams, stream_id) do
        %{resumer: resumer} when is_pid(resumer) ->
          takeover = %{
            stream_id: stream_id,
            resumer: resumer,
            replay: Enum.map(replay, &elem(&1, 0)),
            sent_start: length(model.sent),
            sent_end: nil,
            log: nil
          }

          %{model | takeovers: model.takeovers ++ [takeover]}

        _no_live_resumer ->
          model
      end
    end

    defp record_reply(model, _reply), do: model

    defp close_takeovers(model) do
      takeovers =
        Enum.map(model.takeovers, fn takeover ->
          cond do
            takeover.sent_end != nil ->
              takeover

            open?(model.core, takeover) ->
              takeover

            true ->
              %{takeover | sent_end: length(model.sent), log: log_snapshot(model.core, takeover)}
          end
        end)

      %{model | takeovers: takeovers}
    end

    defp open?(core, %{stream_id: stream_id, resumer: resumer}) do
      match?(%{resumer: ^resumer}, Map.get(core.streams, stream_id))
    end

    defp log_snapshot(core, %{stream_id: stream_id}) do
      core.log |> EventLog.events(stream_id) |> Enum.map(&elem(&1, 0))
    end
  end

  property "the event ids of a stream increase strictly" do
    check all operations <- Model.operations(),
              max_runs: @max_runs do
      model = Model.run(operations)

      for {_stream_id, ids} <- Model.event_numbers(model) do
        numbers = Enum.map(ids, &event_number/1)
        assert numbers == Enum.sort(numbers)
        assert numbers == Enum.uniq(numbers)
      end
    end
  end

  property "an event reaches exactly one live consumer, or none" do
    check all operations <- Model.operations(),
              max_runs: @max_runs do
      model = Model.run(operations)

      for emit <- model.emits do
        if emit.live, do: assert(emit.count == 1), else: assert(emit.count == 0)
      end
    end
  end

  property "the events of one sender keep the order of the calls" do
    check all operations <- Model.operations(),
              max_runs: @max_runs do
      model = Model.run(operations)

      for {client_id, emit_id} <- Model.ordered(model) do
        assert event_number(client_id) < event_number(emit_id)
      end
    end
  end

  property "the end of all requests and waiters leaves nothing" do
    check all operations <- Model.operations(),
              max_runs: @max_runs do
      model = operations |> Model.run() |> Model.end_all()

      assert model.core.requests == %{}
      assert model.core.outbound == %{}
      assert model.core.streams == %{}

      for tag <- Model.tags(model) do
        refute match?({:request, _}, tag)
        refute match?({:outbound, _}, tag)
        refute match?({:owner, _}, tag)
        refute match?({:resumer, _}, tag)
      end
    end
  end

  property "a close_request or an end_request frees every request and its stream" do
    check all operations <- Model.operations(),
              max_runs: @max_runs do
      model = operations |> Model.run() |> Model.close_requests()

      assert model.core.requests == %{}

      for {_stream_id, entry} <- model.core.streams do
        assert Map.has_key?(model.core.requests, entry.request_id)
      end
    end
  end

  property "a take-over sends every live event of the stream to its resumer" do
    check all operations <- Model.operations(),
              max_runs: @max_runs do
      model = Model.run(operations)

      for takeover <- Model.takeovers(model) do
        live = Model.live_events(model, takeover)

        assert Enum.all?(live, &(&1.to == takeover.resumer))

        assert Model.replay_ids(takeover) ++ Enum.map(live, & &1.event_id) ==
                 Model.log_ids(model, takeover)
      end
    end
  end

  property "the tags of the model are the tags of the core" do
    check all operations <- Model.operations(),
              max_runs: @max_runs do
      model = Model.run(operations)

      assert Model.tags(model) == Model.expected_tags(model.core)
      assert MapSet.new(Map.keys(Model.tag_pids(model))) == Model.tags(model)
    end
  end

  property "a resumer DOWN keeps the stream and the next event goes to the owner" do
    check all operations <- Model.operations(),
              max_runs: @max_runs do
      model = Model.run(operations)

      for stream_id <- Model.resumer_streams(model) do
        {model, owner, sent} = Model.resumer_down_and_emit(model, stream_id)

        assert Map.has_key?(model.core.streams, stream_id)
        assert model.core.streams[stream_id].resumer == nil

        if is_pid(owner) do
          assert {^stream_id, _event_id, "after the resumer", ^owner} = sent
        else
          #
          # A stream with no live owner logs the event only.
          #
          refute sent != nil and elem(sent, 0) == stream_id and
                   elem(sent, 2) == "after the resumer"
        end
      end
    end
  end

  property "a run of roots has at most one running pid and one mark" do
    check all operations <- list_of(member_of(@roots_operations), max_length: 40),
              max_runs: @max_runs do
      Enum.reduce(operations, Model.new_roots_core(), fn operation, core ->
        {core, _effects} = Model.run_roots(operation, core)

        assert is_nil(core.roots.running) or is_pid(core.roots.running)
        assert is_boolean(core.roots.again)
        refute is_nil(core.roots.running) and core.roots.again

        core
      end)
    end
  end

  test "a take-over of a live stream sends the next event to its resumer" do
    model = Model.run([:open_request_stream, :take_over, :emit_stream])

    assert [takeover] = Model.takeovers(model)
    live = Model.live_events(model, takeover)

    assert live != []
    assert Enum.all?(live, &(&1.to == takeover.resumer))
  end

  test "a take-over leaves a live resumer at the end of the run" do
    model = Model.run([:open_request_stream, :take_over])

    assert [_stream_id] = Model.resumer_streams(model)
  end

  defp event_number(event_id) do
    {_stream_id, number} = OzMcp.PostStream.parse_event_id(event_id)
    number
  end
end
