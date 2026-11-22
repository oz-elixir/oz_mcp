defmodule OzMcp.ContextTest do
  use ExUnit.Case, async: true

  alias OzMcp.Context
  alias Support.Helpers.Utils
  alias Support.Servers

  # The instance that serves a server module in this file.
  #
  defp inst(module), do: Module.concat(module, __MODULE__)

  describe "new/3" do
    test "initializes progress_token to nil" do
      context = Context.new(SomeServer, :http_streamable, :rpc)

      assert context.progress_token == nil
    end

    test "initializes task fields to nil" do
      context = Context.new(SomeServer, :http_streamable, :rpc)

      assert context.bound == nil
      assert context.task_id == nil
      assert context.tasks_cursor == nil
    end
  end

  describe "to_ctx/1" do
    test "projects the context fields into the public ctx map" do
      context = %Context{
        instance: :some_instance,
        server: inst(Servers.ToolsOnly),
        session_id: "session-1",
        rpc_id: 7,
        progress_token: "tok-1"
      }

      assert Context.to_ctx(context) == %{
               instance: :some_instance,
               server: inst(Servers.ToolsOnly),
               session_id: "session-1",
               request_id: 7,
               progress_token: "tok-1",
               task_id: nil,
               client_capabilities: %{},
               principal: nil
             }
    end

    test "the ctx has the eight keys of the contract" do
      assert Context.to_ctx(%Context{}) |> Map.keys() |> MapSet.new() ==
               MapSet.new([
                 :instance,
                 :server,
                 :session_id,
                 :request_id,
                 :progress_token,
                 :task_id,
                 :client_capabilities,
                 :principal
               ])
    end

    test "carries the principal of the request" do
      principal = OzMcp.Auth.Principal.new!(issuer: "https://issuer.test", subject: "alice")

      context = %Context{principal: principal}

      assert Context.to_ctx(context).principal == principal
    end

    test "the principal is nil when authorization is off" do
      assert Context.to_ctx(%Context{}).principal == nil
    end

    test "carries the capabilities the client declared" do
      context = %Context{client_capabilities: %{"sampling" => %{}}}

      assert Context.to_ctx(context).client_capabilities == %{"sampling" => %{}}
    end

    test "maps rpc_id to request_id (spec language at the public boundary)" do
      context = %Context{rpc_id: "req-42"}

      ctx = Context.to_ctx(context)

      assert ctx.request_id == "req-42"
    end

    test "nil rpc_id yields request_id: nil" do
      context = %Context{rpc_id: nil}

      ctx = Context.to_ctx(context)

      assert ctx.request_id == nil
    end

    test "nil progress_token yields progress_token: nil" do
      context = %Context{}

      ctx = Context.to_ctx(context)

      assert ctx.progress_token == nil
    end

    test "task_id is hardcoded to nil" do
      context = %Context{rpc_id: 1}

      assert Context.to_ctx(context).task_id == nil
    end
  end

  describe "capability?/2" do
    @capabilities %{
      "sampling" => %{"tools" => %{}},
      "elicitation" => %{},
      "roots" => %{"listChanged" => true},
      "off" => nil
    }

    test "is true for a declared capability, even declared as an empty object" do
      assert Context.capability?(@capabilities, :sampling)
      assert Context.capability?(@capabilities, "elicitation")
      assert Context.capability?(@capabilities, :roots)
    end

    test "is false for a capability that is not declared" do
      refute Context.capability?(@capabilities, :tasks)
      refute Context.capability?(%{}, :sampling)
    end

    test "is false for a capability declared with a value that is not an object" do
      refute Context.capability?(@capabilities, :off)
      refute Context.capability?(%{"sampling" => true}, :sampling)
      refute Context.capability?(%{"sampling" => nil}, :sampling)
    end

    test "follows a path of nested members" do
      assert Context.capability?(@capabilities, [:sampling, :tools])
      refute Context.capability?(@capabilities, [:sampling, :context])
      refute Context.capability?(@capabilities, [:roots, :listChanged])
    end

    test "is false when the capabilities are not an object" do
      for capabilities <- [nil, "x", 1, []] do
        refute Context.capability?(capabilities, :sampling)
      end
    end
  end

  describe "client_supports?/2" do
    setup do
      Utils.start_instances([Servers.Default], __MODULE__, allowed_origins: [])
    end

    test "reads the capabilities the client declared for the session" do
      session_id =
        Utils.create_session(
          inst(Servers.Default),
          initialized: true,
          client_capabilities: %{"sampling" => %{}, "roots" => %{}}
        )

      ctx = %{
        instance: inst(Servers.Default),
        server: inst(Servers.Default),
        session_id: session_id
      }

      assert Context.client_supports?(ctx, :sampling)
      assert Context.client_supports?(ctx, "roots")
      refute Context.client_supports?(ctx, :elicitation)
    end

    test "reads the capabilities of the ctx without asking the session" do
      #
      # No session, no server: the answer is in the ctx.
      #
      ctx = %{
        instance: :no_such_server,
        server: :no_such_server,
        session_id: "gone",
        client_capabilities: %{"roots" => %{}}
      }

      assert Context.client_supports?(ctx, :roots)
      refute Context.client_supports?(ctx, :sampling)
    end

    test "the capabilities of the ctx win over the session" do
      session_id =
        Utils.create_session(inst(Servers.Default),
          initialized: true,
          client_capabilities: %{"sampling" => %{}}
        )

      ctx = %{
        instance: inst(Servers.Default),
        server: inst(Servers.Default),
        session_id: session_id,
        client_capabilities: %{}
      }

      refute Context.client_supports?(ctx, :sampling)
    end

    test "accepts a context struct" do
      context = %Context{client_capabilities: %{"sampling" => %{"tools" => %{}}}}

      assert Context.client_supports?(context, [:sampling, :tools])
      refute Context.client_supports?(context, :roots)
    end

    test "is false for a ctx without a session instead of raising" do
      refute Context.client_supports?(%{instance: inst(Servers.Default)}, :sampling)

      refute Context.client_supports?(
               %{instance: inst(Servers.Default), session_id: nil},
               :roots
             )
    end

    test "is false when the session does not exist" do
      ctx = %{
        instance: inst(Servers.Default),
        server: inst(Servers.Default),
        session_id: "gone"
      }

      refute Context.client_supports?(ctx, :sampling)
    end

    test "is false when the server is not running" do
      ctx = %{
        instance: inst(Servers.ToolsOnly),
        server: inst(Servers.ToolsOnly),
        session_id: "any"
      }

      refute Context.client_supports?(ctx, :sampling)
    end

    test "is false for a hand-built ctx without :instance of a live session" do
      session_id =
        Utils.create_session(
          inst(Servers.Default),
          initialized: true,
          client_capabilities: %{"sampling" => %{}}
        )

      ctx = %{
        server: inst(Servers.Default),
        session_id: session_id
      }

      refute Context.client_supports?(ctx, :sampling)

      assert Context.client_supports?(
               Map.put(ctx, :instance, inst(Servers.Default)),
               :sampling
             )
    end
  end

  describe "client_task_support?/2" do
    @task_capabilities %{
      "tasks" => %{
        "requests" => %{
          "sampling" => %{"createMessage" => %{}},
          "elicitation" => %{"create" => %{}}
        }
      }
    }

    test "is true for each method that the client runs as a task" do
      for method <- ["sampling/createMessage", "elicitation/create"] do
        ctx = %{client_capabilities: @task_capabilities}

        assert Context.client_task_support?(ctx, method),
               "the client runs #{method} as a task"
      end
    end

    test "reads one request of the capability only" do
      ctx = %{
        client_capabilities: %{
          "tasks" => %{"requests" => %{"sampling" => %{"createMessage" => %{}}}}
        }
      }

      assert Context.client_task_support?(ctx, "sampling/createMessage")
      refute Context.client_task_support?(ctx, "elicitation/create")
    end

    test "is false with no task capability" do
      for capabilities <- [%{}, %{"tasks" => %{}}, %{"sampling" => %{}}] do
        for method <- ["sampling/createMessage", "elicitation/create"] do
          refute Context.client_task_support?(%{client_capabilities: capabilities}, method)
        end
      end
    end

    test "is false for a method that the client cannot run as a task" do
      ctx = %{client_capabilities: @task_capabilities}

      refute Context.client_task_support?(ctx, "roots/list")
      refute Context.client_task_support?(ctx, "ping")
    end

    test "is false for a ctx without capabilities" do
      refute Context.client_task_support?(%{}, "sampling/createMessage")
      refute Context.client_task_support?(%{instance: :no_such_server}, "elicitation/create")
    end

    test "accepts a context struct" do
      context = %Context{client_capabilities: @task_capabilities}

      assert Context.client_task_support?(context, "sampling/createMessage")
      assert Context.client_task_support?(context, "elicitation/create")
    end
  end

  describe "task_capability?/2" do
    @sampling_task_capabilities %{
      "tasks" => %{"requests" => %{"sampling" => %{"createMessage" => %{}}}}
    }

    test "reads the capability of the method in a map of capabilities" do
      assert Context.task_capability?(@sampling_task_capabilities, "sampling/createMessage")
      refute Context.task_capability?(@sampling_task_capabilities, "elicitation/create")
    end

    test "is false for a method that the client cannot run as a task" do
      refute Context.task_capability?(@sampling_task_capabilities, "roots/list")
    end

    test "is false when the capabilities are not an object" do
      for capabilities <- [nil, "x", 1, []] do
        refute Context.task_capability?(capabilities, "sampling/createMessage")
      end
    end
  end

  describe "request?/1" do
    test "is true only for the kind :request" do
      assert Context.request?(%Context{rpc_kind: :request})
    end

    test "is false for the other kinds" do
      refute Context.request?(%Context{rpc_kind: :notification})
      refute Context.request?(%Context{rpc_kind: :response})
      refute Context.request?(%Context{rpc_kind: :invalid})
    end

    test "is false when the JSON-RPC validation did not run" do
      refute Context.request?(%Context{})
      assert %Context{}.rpc_kind == nil
    end
  end
end
