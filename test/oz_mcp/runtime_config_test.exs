defmodule OzMcp.RuntimeConfigTest do
  #
  # Sync: the runtime of the tests has a fixed name and the instances have the names of their server modules.
  #
  use ExUnit.Case, async: false
  import Support.Factories.Server
  alias Support.Helpers.Utils
  alias Support.Servers
  require Support.Factories.Tool

  describe "start_link/1 config validation" do
    test "raises when :allowed_origins is not a list" do
      config = %{servers: [Servers.Default], allowed_origins: "https://a.example"}

      assert_raise ArgumentError,
                   ~s{allowed_origins must be a list, got: "https://a.example"},
                   fn -> Utils.start_runtime(config) end
    end

    test "accepts a list of :allowed_origins" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [Servers.Default],
          allowed_origins: ["http://localhost:3000"]
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert %OzMcp.Instance.Config{} = config
    end

    test "gives the list of :allowed_origins to each server" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [Servers.Default],
          allowed_origins: ["http://localhost:3000"]
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, %{allowed_origins: ["http://localhost:3000"]}} =
               OzMcp.Instance.fetch_opts(Servers.Default)
    end

    test "gives an empty list of :allowed_origins to a server of :stdio with no list" do
      {:ok, _pid} =
        Utils.start_runtime(%{transport: :stdio, servers: [Servers.Default]})

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, %{allowed_origins: []}} =
               OzMcp.Instance.fetch_opts(Servers.Default)
    end

    test "raises when an element of :allowed_origins is \"*\"" do
      config = %{servers: [Servers.Default], allowed_origins: ["*"]}

      assert_raise ArgumentError,
                   ~s{allowed_origins: "*" is not a wildcard. Give each origin, } <>
                     ~s{for example "https://app.example.com"},
                   fn -> Utils.start_runtime(config) end
    end

    test "raises when an element of :allowed_origins is not a string" do
      config = %{servers: [Servers.Default], allowed_origins: [:localhost]}

      assert_raise ArgumentError,
                   "allowed_origins must hold non-empty strings, got: :localhost",
                   fn -> Utils.start_runtime(config) end
    end

    test "raises when an element of :allowed_origins is an empty string" do
      config = %{servers: [Servers.Default], allowed_origins: [""]}

      assert_raise ArgumentError,
                   ~s{allowed_origins must hold non-empty strings, got: ""},
                   fn -> Utils.start_runtime(config) end
    end

    test "raises when session_init_timeout_ms is not a positive integer" do
      for value <- [1.5, "thirty", 0, -30, nil] do
        config = %{
          servers: [{Servers.Default, %{session_init_timeout_ms: value}}],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     "session_init_timeout_ms must be a positive integer, got: #{inspect(value)}",
                     fn -> Utils.start_runtime(config) end
      end
    end

    test "accepts a positive integer session_init_timeout_ms" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{session_init_timeout_ms: 1_000}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)
      assert config.opts.session_init_timeout_ms == 1_000
    end

    test "raises when request_timeout_ms is zero or negative" do
      zero = %{
        servers: [{Servers.Default, %{request_timeout_ms: 0}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "request_timeout_ms must be a positive integer (ms) or nil, got: 0",
                   fn -> Utils.start_runtime(zero) end

      negative = %{
        servers: [{Servers.Default, %{request_timeout_ms: -1}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "request_timeout_ms must be a positive integer (ms) or nil, got: -1",
                   fn -> Utils.start_runtime(negative) end
    end

    test "raises when request_timeout_ms is not a number" do
      config = %{
        servers: [{Servers.Default, %{request_timeout_ms: "soon"}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   ~r{request_timeout_ms must be a positive integer \(ms\) or nil, got: "soon"},
                   fn -> Utils.start_runtime(config) end
    end

    test "accepts nil and positive integers for request_timeout_ms" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{request_timeout_ms: 500}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.request_timeout_ms == 500

      Utils.stop_runtime()

      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{request_timeout_ms: nil}}],
          allowed_origins: []
        })

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.request_timeout_ms == nil
    end

    test "raises when request_cancel_grace_ms is not a positive integer" do
      for invalid <- [0, -1, "soon", nil, :infinity] do
        config = %{
          servers: [{Servers.Default, %{request_cancel_grace_ms: invalid}}],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     "request_cancel_grace_ms must be a positive integer (ms), got: #{inspect(invalid)}",
                     fn -> Utils.start_runtime(config) end
      end
    end

    test "raises when client_request_timeout_ms is not a positive integer or :infinity" do
      for invalid <- [0, -1, 1.5, "60", nil] do
        config = %{
          servers: [{Servers.Default, %{client_request_timeout_ms: invalid}}],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     "client_request_timeout_ms must be a positive integer (ms) or :infinity, got: #{inspect(invalid)}",
                     fn -> Utils.start_runtime(config) end
      end
    end

    for key <- [:elicitation_timeout_ms, :sampling_timeout_ms] do
      test "raises when #{key} is not a positive integer or :infinity" do
        for invalid <- [0, -1, 1.5, nil, "1000"] do
          assert_raise ArgumentError,
                       "#{unquote(key)} must be a positive integer (ms) or :infinity, got: #{inspect(invalid)}",
                       fn ->
                         Utils.start_runtime(%{
                           servers: [{Servers.Default, %{unquote(key) => invalid}}],
                           allowed_origins: []
                         })
                       end
        end
      end
    end

    test "elicitation_timeout_ms and sampling_timeout_ms default to 5 and 2 minutes and accept :infinity" do
      {:ok, _pid} =
        Utils.start_runtime(%{servers: [Servers.Default], allowed_origins: []})

      assert OzMcp.Instance.opts(Servers.Default).elicitation_timeout_ms == 300_000
      assert OzMcp.Instance.opts(Servers.Default).sampling_timeout_ms == 120_000
      Utils.stop_runtime()

      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [
            {Servers.Default, %{elicitation_timeout_ms: :infinity, sampling_timeout_ms: 5}}
          ],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert OzMcp.Instance.opts(Servers.Default).elicitation_timeout_ms == :infinity
      assert OzMcp.Instance.opts(Servers.Default).sampling_timeout_ms == 5
    end

    test "client_request_timeout_ms defaults to 60000 ms and accepts :infinity" do
      {:ok, _pid} =
        Utils.start_runtime(%{servers: [Servers.Default], allowed_origins: []})

      on_exit(fn -> Utils.stop_runtime() end)

      assert OzMcp.Instance.opts(Servers.Default).client_request_timeout_ms == 60_000
      Utils.stop_runtime()

      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{client_request_timeout_ms: :infinity}}],
          allowed_origins: []
        })

      assert OzMcp.Instance.opts(Servers.Default).client_request_timeout_ms ==
               :infinity
    end

    test "client_tasks defaults to false and accepts true" do
      {:ok, _pid} =
        Utils.start_runtime(%{servers: [Servers.Default], allowed_origins: []})

      on_exit(fn -> Utils.stop_runtime() end)

      assert OzMcp.Instance.opts(Servers.Default).client_tasks == false

      Utils.stop_runtime()

      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{client_tasks: true}}],
          allowed_origins: []
        })

      assert OzMcp.Instance.opts(Servers.Default).client_tasks == true
    end

    test "raises when client_tasks is not a boolean" do
      config = %{
        servers: [{Servers.Default, %{client_tasks: "yes"}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   ~s(client_tasks must be a boolean, got: "yes"),
                   fn -> Utils.start_runtime(config) end
    end

    test "client_task_poll_interval_ms defaults to 2000 ms and accepts a positive integer" do
      {:ok, _pid} =
        Utils.start_runtime(%{servers: [Servers.Default], allowed_origins: []})

      on_exit(fn -> Utils.stop_runtime() end)

      assert OzMcp.Instance.opts(Servers.Default).client_task_poll_interval_ms ==
               2_000

      Utils.stop_runtime()

      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{client_task_poll_interval_ms: 250}}],
          allowed_origins: []
        })

      assert OzMcp.Instance.opts(Servers.Default).client_task_poll_interval_ms ==
               250
    end

    test "raises when client_task_poll_interval_ms is not a positive integer" do
      for invalid <- [0, -1, 1.5, "2000", nil, :infinity] do
        config = %{
          servers: [{Servers.Default, %{client_task_poll_interval_ms: invalid}}],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     "client_task_poll_interval_ms must be a positive integer, got: #{inspect(invalid)}",
                     fn -> Utils.start_runtime(config) end
      end
    end

    test "request_cancel_grace_ms defaults to 1000 ms and accepts a positive integer" do
      {:ok, _pid} =
        Utils.start_runtime(%{servers: [Servers.Default], allowed_origins: []})

      on_exit(fn -> Utils.stop_runtime() end)

      assert OzMcp.Instance.opts(Servers.Default).request_cancel_grace_ms == 1000
      Utils.stop_runtime()

      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{request_cancel_grace_ms: 250}}],
          allowed_origins: []
        })

      assert OzMcp.Instance.opts(Servers.Default).request_cancel_grace_ms == 250
    end

    test "publishes the execution opts in the config of the instance" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [
            {Servers.Default, %{request_timeout_ms: 500, request_cancel_grace_ms: 250}}
          ],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts == %{
               OzMcp.Instance.Config.default_opts()
               | request_timeout_ms: 500,
                 request_cancel_grace_ms: 250
             }

      assert OzMcp.Instance.opts(Servers.Default) == config.opts
      assert OzMcp.Instance.opts(Servers.Default).request_timeout_ms == 500
      assert OzMcp.Instance.opts(Servers.Default).request_cancel_grace_ms == 250
    end

    test "execution opts fall back to the defaults when the server is not running" do
      assert OzMcp.Instance.opts(:no_such_server) == OzMcp.Instance.Config.default_opts()

      assert OzMcp.Instance.opts(:no_such_server).request_timeout_ms == nil
    end

    test "fetch_opts/1 tells a running server from a missing one" do
      assert OzMcp.Instance.fetch_opts(:no_such_server) == :not_running

      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{request_timeout_ms: 500}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert OzMcp.Instance.fetch_opts(Servers.Default) == {:ok, config.opts}

      assert OzMcp.Instance.fetch_opts(:no_such_server) == :not_running
    end

    test "Schema.defaults/0 is the single source of the defaults" do
      assert OzMcp.Instance.Config.default_opts() ==
               Map.put(OzMcp.Instance.Config.Schema.defaults(), :resource_metadata_url, nil)
    end

    test "raises when sse_heartbeat_ms is zero or negative" do
      zero = %{
        servers: [{Servers.Default, %{sse_heartbeat_ms: 0}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "sse_heartbeat_ms must be a positive integer (ms) or :infinity, got: 0",
                   fn -> Utils.start_runtime(zero) end

      negative = %{
        servers: [{Servers.Default, %{sse_heartbeat_ms: -100}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "sse_heartbeat_ms must be a positive integer (ms) or :infinity, got: -100",
                   fn -> Utils.start_runtime(negative) end
    end

    test "raises when sse_heartbeat_ms is not a number" do
      text = %{
        servers: [{Servers.Default, %{sse_heartbeat_ms: "soon"}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   ~r{sse_heartbeat_ms must be a positive integer \(ms\) or :infinity, got: "soon"},
                   fn -> Utils.start_runtime(text) end

      float = %{
        servers: [{Servers.Default, %{sse_heartbeat_ms: 1.5}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "sse_heartbeat_ms must be a positive integer (ms) or :infinity, got: 1.5",
                   fn -> Utils.start_runtime(float) end
    end

    test "accepts :infinity and positive integers for sse_heartbeat_ms" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{sse_heartbeat_ms: :infinity}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.sse_heartbeat_ms == :infinity
    end

    test "raises when sse_retry_ms is zero, negative, a float, nil or a string" do
      for invalid <- [0, -1, 1.5, "x", nil] do
        config = %{
          servers: [{Servers.Default, %{sse_retry_ms: invalid}}],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     "sse_retry_ms must be a positive integer (ms), got: #{inspect(invalid)}",
                     fn -> Utils.start_runtime(config) end
      end
    end

    test "accepts a positive integer sse_retry_ms and publishes it in the opts" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{sse_retry_ms: 250}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, opts} = OzMcp.Instance.fetch_opts(Servers.Default)
      assert opts.sse_retry_ms == 250
      assert opts.sse_max_stream_ms == nil
    end

    test "raises when sse_max_stream_ms is zero, negative, :infinity or a string" do
      for invalid <- [0, -5, :infinity, "x"] do
        config = %{
          servers: [{Servers.Default, %{sse_max_stream_ms: invalid}}],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     "sse_max_stream_ms must be a positive integer (ms) or nil, got: #{inspect(invalid)}",
                     fn -> Utils.start_runtime(config) end
      end
    end

    test "accepts nil and a positive integer sse_max_stream_ms" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{sse_max_stream_ms: 5000}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.sse_max_stream_ms == 5000

      Utils.stop_runtime()

      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{sse_max_stream_ms: nil}}],
          allowed_origins: []
        })

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.sse_max_stream_ms == nil
    end

    test "the sse retry and stream opts default to 1000 ms and nil" do
      {:ok, _pid} =
        Utils.start_runtime(%{servers: [Servers.Default], allowed_origins: []})

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      opts = config.opts
      assert opts.sse_retry_ms == 1000
      assert opts.sse_max_stream_ms == nil
    end

    test "raises when sse_event_log_size is zero or negative" do
      zero = %{
        servers: [{Servers.Default, %{sse_event_log_size: 0}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "sse_event_log_size must be a positive integer, got: 0",
                   fn -> Utils.start_runtime(zero) end

      negative = %{
        servers: [{Servers.Default, %{sse_event_log_size: -256}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "sse_event_log_size must be a positive integer, got: -256",
                   fn -> Utils.start_runtime(negative) end
    end

    test "raises when sse_event_log_size is not a number" do
      config = %{
        servers: [{Servers.Default, %{sse_event_log_size: "big"}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   ~r{sse_event_log_size must be a positive integer, got: "big"},
                   fn -> Utils.start_runtime(config) end
    end

    test "raises when max_token_bytes is zero or negative" do
      zero = %{
        servers: [{Servers.Default, %{max_token_bytes: 0}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "max_token_bytes must be a positive integer, got: 0",
                   fn -> Utils.start_runtime(zero) end

      negative = %{
        servers: [{Servers.Default, %{max_token_bytes: -1}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "max_token_bytes must be a positive integer, got: -1",
                   fn -> Utils.start_runtime(negative) end
    end

    test "raises when max_token_bytes is not a number" do
      config = %{
        servers: [{Servers.Default, %{max_token_bytes: "big"}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   ~r{max_token_bytes must be a positive integer, got: "big"},
                   fn -> Utils.start_runtime(config) end
    end

    test "publishes a custom max_token_bytes in the opts" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{max_token_bytes: 16_384}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert OzMcp.Instance.opts(Servers.Default).max_token_bytes == 16_384
    end

    test "raises when max_body_bytes is zero, negative, nil or not a number" do
      for invalid <- [0, -1, nil, "1", 1.5] do
        config = %{
          servers: [{Servers.Default, %{max_body_bytes: invalid}}],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     "max_body_bytes must be a positive integer, got: #{inspect(invalid)}",
                     fn -> Utils.start_runtime(config) end
      end
    end

    test "accepts a positive integer max_body_bytes and keeps it in the server opts" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{max_body_bytes: 2_048}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)
      assert config.opts.max_body_bytes == 2_048
    end

    test "accepts nil and a positive integer max_sessions" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{max_sessions: nil}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.max_sessions == nil

      Utils.stop_runtime()

      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{max_sessions: 10}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.max_sessions == 10
    end

    test "raises when max_sessions is not a positive integer" do
      for invalid <- [0, -1, 1.5, "10"] do
        config = %{
          servers: [{Servers.Default, %{max_sessions: invalid}}],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     "max_sessions must be a positive integer or nil, got: #{inspect(invalid)}",
                     fn -> Utils.start_runtime(config) end
      end
    end

    test "accepts nil and a positive integer max_sessions_per_principal" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{max_sessions_per_principal: nil}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.max_sessions_per_principal == nil

      Utils.stop_runtime()

      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{max_sessions_per_principal: 5}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.max_sessions_per_principal == 5
    end

    test "raises when max_sessions_per_principal is not a positive integer" do
      for invalid <- [0, -1, 1.5, "10"] do
        config = %{
          servers: [{Servers.Default, %{max_sessions_per_principal: invalid}}],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     "max_sessions_per_principal must be a positive integer or nil, got: #{inspect(invalid)}",
                     fn -> Utils.start_runtime(config) end
      end
    end

    test "accepts nil and a positive integer max_streams_per_session" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{max_streams_per_session: nil}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.max_streams_per_session == nil

      Utils.stop_runtime()

      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{max_streams_per_session: 5}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.max_streams_per_session == 5
    end

    test "raises when max_streams_per_session is not a positive integer" do
      for invalid <- [0, -1, 1.5, "10"] do
        config = %{
          servers: [{Servers.Default, %{max_streams_per_session: invalid}}],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     "max_streams_per_session must be a positive integer or nil, got: #{inspect(invalid)}",
                     fn -> Utils.start_runtime(config) end
      end
    end

    test "accepts nil and a positive integer max_subscriptions_per_session" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{max_subscriptions_per_session: nil}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.max_subscriptions_per_session == nil

      Utils.stop_runtime()

      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{max_subscriptions_per_session: 5}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.max_subscriptions_per_session == 5
    end

    test "raises when max_subscriptions_per_session is not a positive integer" do
      for invalid <- [0, -1, 1.5, "10"] do
        config = %{
          servers: [{Servers.Default, %{max_subscriptions_per_session: invalid}}],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     "max_subscriptions_per_session must be a positive integer or nil, got: #{inspect(invalid)}",
                     fn -> Utils.start_runtime(config) end
      end
    end

    test "accepts nil and a positive integer sse_event_log_max_streams" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{sse_event_log_max_streams: nil}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.sse_event_log_max_streams == nil

      Utils.stop_runtime()

      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{sse_event_log_max_streams: 5}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.sse_event_log_max_streams == 5
    end

    test "raises when sse_event_log_max_streams is not a positive integer" do
      for invalid <- [0, -1, 1.5, "10"] do
        config = %{
          servers: [{Servers.Default, %{sse_event_log_max_streams: invalid}}],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     "sse_event_log_max_streams must be a positive integer or nil, got: #{inspect(invalid)}",
                     fn -> Utils.start_runtime(config) end
      end
    end

    test "raises when task_default_ttl_ms is zero, negative or not a number" do
      for invalid <- [0, -1, 1.5, "1"] do
        config = %{
          servers: [{Servers.Default, %{task_default_ttl_ms: invalid}}],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     "task_default_ttl_ms must be a positive integer (ms) at most 31536000000 or nil, got: #{inspect(invalid)}",
                     fn -> Utils.start_runtime(config) end
      end
    end

    test "raises when task_max_ttl_ms is zero, negative or not a number" do
      for invalid <- [0, -1, 1.5, "1"] do
        config = %{
          servers: [{Servers.Default, %{task_max_ttl_ms: invalid}}],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     "task_max_ttl_ms must be a positive integer (ms) at most 31536000000 or nil, got: #{inspect(invalid)}",
                     fn -> Utils.start_runtime(config) end
      end
    end

    test "raises when a task ttl option is above the ceiling" do
      for key <- [:task_default_ttl_ms, :task_max_ttl_ms] do
        config = %{
          servers: [
            {Servers.Default, Map.put(%{task_max_ttl_ms: nil}, key, 31_536_000_001)}
          ],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     "#{key} must be a positive integer (ms) at most 31536000000 or nil, got: 31536000001",
                     fn -> Utils.start_runtime(config) end
      end
    end

    test "accepts a task ttl option at the ceiling" do
      configs = [
        %{task_default_ttl_ms: 31_536_000_000, task_max_ttl_ms: nil},
        %{task_max_ttl_ms: 31_536_000_000},
        %{task_default_ttl_ms: 31_536_000_000, task_max_ttl_ms: 31_536_000_000}
      ]

      for opts <- configs do
        {:ok, _pid} =
          Utils.start_runtime(%{
            servers: [{Servers.Default, opts}],
            allowed_origins: []
          })

        Utils.stop_runtime()
      end

      assert :ok
    end

    test "accepts nil and positive integers for the two task ttl options" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [
            {Servers.Default, %{task_default_ttl_ms: 5_000, task_max_ttl_ms: 60_000}}
          ],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      opts = config.opts
      assert opts.task_default_ttl_ms == 5_000
      assert opts.task_max_ttl_ms == 60_000

      Utils.stop_runtime()

      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{task_default_ttl_ms: nil, task_max_ttl_ms: nil}}],
          allowed_origins: []
        })

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      opts = config.opts
      assert opts.task_default_ttl_ms == nil
      assert opts.task_max_ttl_ms == nil
    end

    test "gives task_max_ttl_ms the default of 24 hours and task_default_ttl_ms no default" do
      {:ok, _pid} =
        Utils.start_runtime(%{servers: [Servers.Default], allowed_origins: []})

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      opts = config.opts
      assert opts.task_default_ttl_ms == nil
      assert opts.task_max_ttl_ms == 86_400_000
    end

    test "accepts nil and a positive integer max_tasks_per_session" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{max_tasks_per_session: nil}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.max_tasks_per_session == nil

      Utils.stop_runtime()

      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{max_tasks_per_session: 5}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.max_tasks_per_session == 5
    end

    test "raises when max_tasks_per_session is not a positive integer" do
      for invalid <- [0, -1, 1.5, "10"] do
        config = %{
          servers: [{Servers.Default, %{max_tasks_per_session: invalid}}],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     "max_tasks_per_session must be a positive integer or nil, got: #{inspect(invalid)}",
                     fn -> Utils.start_runtime(config) end
      end
    end

    test "gives the task owner options their defaults" do
      {:ok, _pid} =
        Utils.start_runtime(%{servers: [Servers.Default], allowed_origins: []})

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.max_tasks_per_principal == 1_000
      assert config.opts.tasks_follow_session == true
    end

    test "raises when max_tasks_per_principal is not a positive integer or nil" do
      for invalid <- [0, -1, 1.5, "10"] do
        config = %{
          servers: [{Servers.Default, %{max_tasks_per_principal: invalid}}],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     "max_tasks_per_principal must be a positive integer or nil, got: #{inspect(invalid)}",
                     fn -> Utils.start_runtime(config) end
      end
    end

    test "raises when tasks_follow_session is not a boolean" do
      config = %{
        servers: [{Servers.Default, %{tasks_follow_session: "yes"}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   ~s(tasks_follow_session must be a boolean, got: "yes"),
                   fn -> Utils.start_runtime(config) end
    end

    test "gives the result check options their default of true" do
      {:ok, _pid} =
        Utils.start_runtime(%{servers: [Servers.Default], allowed_origins: []})

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.check_results == true
      assert config.opts.check_output_schemas == true
    end

    test "accepts false for the result check options and publishes them in the opts" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{check_results: false}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.check_results == false
      assert config.opts.check_output_schemas == true
    end

    test "gives max_tasks_per_session the default of 100" do
      {:ok, _pid} =
        Utils.start_runtime(%{servers: [Servers.Default], allowed_origins: []})

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.max_tasks_per_session == 100
    end

    test "gives the task record options their defaults" do
      {:ok, _pid} =
        Utils.start_runtime(%{servers: [Servers.Default], allowed_origins: []})

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.max_task_records_per_owner == 1_000
      assert config.opts.max_task_bytes_per_owner == 67_108_864
    end

    test "refuses max_tasks_per_session higher than max_task_records_per_owner" do
      config = %{
        servers: [
          {Servers.Default, %{max_tasks_per_session: 2_000, max_task_records_per_owner: 1_000}}
        ],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "max_tasks_per_session (2000) must not be higher than max_task_records_per_owner (1000)",
                   fn -> Utils.start_runtime(config) end
    end

    test "refuses max_tasks_per_principal higher than max_task_records_per_owner" do
      config = %{
        servers: [
          {Servers.Default, %{max_tasks_per_principal: 2_000, max_task_records_per_owner: 1_000}}
        ],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "max_tasks_per_principal (2000) must not be higher than max_task_records_per_owner (1000)",
                   fn -> Utils.start_runtime(config) end
    end

    test "accepts nil max_task_records_per_owner and nil max_task_bytes_per_owner" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [
            {Servers.Default, %{max_task_records_per_owner: nil, max_task_bytes_per_owner: nil}}
          ],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      assert config.opts.max_task_records_per_owner == nil
      assert config.opts.max_task_bytes_per_owner == nil
    end

    test "merges the sse defaults into the server opts" do
      {:ok, _pid} =
        Utils.start_runtime(%{servers: [Servers.Default], allowed_origins: []})

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      opts = config.opts
      assert opts.sse_heartbeat_ms == 15_000
      assert opts.sse_event_log_size == 256
      assert opts.sse_event_log_session_bytes == 8_388_608
      assert opts.sse_event_log_max_streams == 256
      assert opts.sse_resume_window_ms == 300_000

      assert OzMcp.Instance.opts(Servers.Default).sse_heartbeat_ms == 15_000
    end

    # A guard for the text: the option text of `OzMcp` and the two guides
    # state this default and its reason (well under the idle timeout of
    # the proxies and of Cowboy). A change of the default must update
    # that text too.
    #
    test "the default of sse_heartbeat_ms is 15 s" do
      assert OzMcp.Instance.Config.Schema.defaults().sse_heartbeat_ms == 15_000
    end

    test "honors sse opts overrides and exposes them through the opts" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{sse_heartbeat_ms: 100, sse_event_log_size: 32}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)

      opts = config.opts
      assert opts.sse_heartbeat_ms == 100
      assert opts.sse_event_log_size == 32

      assert OzMcp.Instance.opts(Servers.Default).sse_heartbeat_ms == 100
    end

    test "accepts a resume window of zero" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{sse_resume_window_ms: 0}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)
      assert config.opts.sse_resume_window_ms == 0
    end

    test "raises when sse_resume_window_ms is negative or not a number" do
      negative = %{
        servers: [{Servers.Default, %{sse_resume_window_ms: -1}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "sse_resume_window_ms must be a non-negative integer, got: -1",
                   fn -> Utils.start_runtime(negative) end

      text = %{
        servers: [{Servers.Default, %{sse_resume_window_ms: "x"}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   ~r{sse_resume_window_ms must be a non-negative integer, got: "x"},
                   fn -> Utils.start_runtime(text) end
    end

    test "gives session_restore_miss_ttl_ms the default of 5000" do
      {:ok, _pid} =
        Utils.start_runtime(%{servers: [Servers.Default], allowed_origins: []})

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)
      assert config.opts.session_restore_miss_ttl_ms == 5_000
    end

    test "accepts a restore miss ttl of zero" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Default, %{session_restore_miss_ttl_ms: 0}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)
      assert config.opts.session_restore_miss_ttl_ms == 0
    end

    test "raises when session_restore_miss_ttl_ms is negative or not a number" do
      negative = %{
        servers: [{Servers.Default, %{session_restore_miss_ttl_ms: -1}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "session_restore_miss_ttl_ms must be a non-negative integer, got: -1",
                   fn -> Utils.start_runtime(negative) end

      text = %{
        servers: [{Servers.Default, %{session_restore_miss_ttl_ms: "x"}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   ~r{session_restore_miss_ttl_ms must be a non-negative integer, got: "x"},
                   fn -> Utils.start_runtime(text) end
    end

    test "raises when sse_event_log_session_bytes is zero or negative" do
      zero = %{
        servers: [{Servers.Default, %{sse_event_log_session_bytes: 0}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "sse_event_log_session_bytes must be a positive integer, got: 0",
                   fn -> Utils.start_runtime(zero) end

      negative = %{
        servers: [{Servers.Default, %{sse_event_log_session_bytes: -1}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "sse_event_log_session_bytes must be a positive integer, got: -1",
                   fn -> Utils.start_runtime(negative) end
    end

    test "raises when sse_event_log_session_bytes is lower than sse_event_log_bytes" do
      config = %{
        servers: [
          {Servers.Default, %{sse_event_log_session_bytes: 10, sse_event_log_bytes: 20}}
        ],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "sse_event_log_session_bytes (10) must not be lower than " <>
                     "sse_event_log_bytes (20)",
                   fn -> Utils.start_runtime(config) end
    end

    test "raises when sse_event_log_bytes alone is above the default session budget" do
      config = %{
        servers: [{Servers.Default, %{sse_event_log_bytes: 16_777_216}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "sse_event_log_session_bytes (8388608) must not be lower than " <>
                     "sse_event_log_bytes (16777216)",
                   fn -> Utils.start_runtime(config) end
    end
  end

  describe "start_link/1 resource_url and authorization setup" do
    test "raises when the server declares an authorization block and the opts set no resource_url" do
      config = %{servers: [{Servers.Authorized, %{}}], allowed_origins: []}

      assert_raise ArgumentError,
                   "server Support.Servers.Authorized declares an authorization block, " <>
                     "its opts must set :resource_url",
                   fn -> Utils.start_runtime(config) end
    end

    test "raises for a bare module entry of a server that declares an authorization block" do
      config = %{servers: [Servers.Authorized], allowed_origins: []}

      assert_raise ArgumentError,
                   "server Support.Servers.Authorized declares an authorization block, " <>
                     "its opts must set :resource_url",
                   fn -> Utils.start_runtime(config) end
    end

    test "raises when resource_url is set but the server declares no authorization block" do
      config = %{
        servers: [{Servers.Default, %{resource_url: "https://mcp.example.com/mcp"}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "server Support.Servers.Default sets :resource_url but declares no authorization block",
                   fn -> Utils.start_runtime(config) end
    end

    test "raises when the verifier of the authorization block is not a loaded module" do
      server =
        module "AuthorizedUnknownVerifier" do
          authorization do
            verifier(NoSuchVerifierForRuntimeCheck)
            authorization_servers(["https://auth.example.com"])
          end
        end
        |> compile()

      config = %{
        servers: [{server, %{resource_url: "https://mcp.example.com/mcp"}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "server #{inspect(server)}: the authorization verifier " <>
                     "NoSuchVerifierForRuntimeCheck is not a loaded module",
                   fn -> Utils.start_runtime(config) end
    end

    test "raises when the verifier of the authorization block does not export authenticate/2" do
      server =
        module "AuthorizedBadVerifier" do
          authorization do
            verifier(OzMcp.Auth)
            authorization_servers(["https://auth.example.com"])
          end
        end
        |> compile()

      config = %{
        servers: [{server, %{resource_url: "https://mcp.example.com/mcp"}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "server #{inspect(server)}: the authorization verifier OzMcp.Auth " <>
                     "must export authenticate/2",
                   fn -> Utils.start_runtime(config) end
    end

    test "raises when resource_url is not a canonical URI" do
      for url <- [
            123,
            "mcp.example.com/mcp",
            "http://mcp.example.com/mcp",
            "http://192.168.0.1/mcp",
            "http://localhost.example.com/mcp",
            "https:///mcp",
            "https://user:pass@mcp.example.com/mcp",
            "https://mcp.example.com/mcp?x=1",
            "https://mcp.example.com/mcp#frag",
            "https://mcp.example.com/mcp/"
          ] do
        config = %{
          servers: [{Servers.Authorized, %{resource_url: url}}],
          allowed_origins: []
        }

        assert_raise ArgumentError,
                     ":resource_url must be a canonical URI " <>
                       "(https scheme, or http for a loopback host (localhost, 127.0.0.1, ::1); " <>
                       "no query, no fragment, " <>
                       "no user info, no trailing slash), got: #{inspect(url)}",
                     fn -> Utils.start_runtime(config) end
      end
    end

    test "accepts canonical resource_url values" do
      for url <- [
            "https://mcp.example.com/mcp",
            "https://mcp.example.com",
            "https://mcp.example.com/",
            "HTTPS://MCP.Example.Com/mcp",
            "https://mcp.example.com:8443/mcp",
            "http://localhost:4000/mcp",
            "http://127.0.0.1:4000/mcp",
            "http://[::1]:4000/mcp"
          ] do
        config = %{
          servers: [{Servers.Authorized, %{resource_url: url}}],
          allowed_origins: []
        }

        assert {:ok, _pid} = Utils.start_runtime(config)
        Utils.stop_runtime()
      end
    end

    test "publishes resource_url and the metadata URL in the opts" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [
            {Servers.Authorized, %{resource_url: "https://mcp.example.com/mcp"}}
          ],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, opts} = OzMcp.Instance.fetch_opts(Servers.Authorized)
      assert opts.resource_url == "https://mcp.example.com/mcp"

      assert opts.resource_metadata_url ==
               "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"
    end

    test "publishes the resource_url with a lower-case scheme and host and the path unchanged" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{Servers.Authorized, %{resource_url: "HTTPS://MCP.Example.Com/Mcp"}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, opts} = OzMcp.Instance.fetch_opts(Servers.Authorized)
      assert opts.resource_url == "https://mcp.example.com/Mcp"

      assert opts.resource_metadata_url ==
               "https://mcp.example.com/.well-known/oauth-protected-resource/Mcp"
    end

    test "publishes the resource_url without the default port of the scheme" do
      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [
            {Servers.Authorized, %{resource_url: "https://mcp.example.com:443/mcp"}}
          ],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, opts} = OzMcp.Instance.fetch_opts(Servers.Authorized)
      assert opts.resource_url == "https://mcp.example.com/mcp"
    end

    test "publishes nil resource keys for a server without authorization" do
      {:ok, _pid} =
        Utils.start_runtime(%{servers: [Servers.Default], allowed_origins: []})

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, opts} = OzMcp.Instance.fetch_opts(Servers.Default)
      assert opts.resource_url == nil
      assert opts.resource_metadata_url == nil
    end
  end

  describe "start_link/1 transport option" do
    test "boots a server for :stdio without :allowed_origins" do
      {:ok, _pid} =
        Utils.start_runtime(%{transport: :stdio, servers: [Servers.Default]})

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, _config} = OzMcp.Instance.config(Servers.Default)
    end

    test "boots a protected server for :stdio without :resource_url and logs that the authorization block is not used" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Utils.start_runtime(%{transport: :stdio, servers: [Servers.Scoped]})
        end)

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, _config} = OzMcp.Instance.config(Servers.Scoped)
      assert log =~ "server Support.Servers.Scoped declares an authorization block"
      assert log =~ "not used on the stdio transport"
    end

    test "the same protected config without :resource_url still raises for :http" do
      config = %{servers: [Servers.Scoped], allowed_origins: []}

      assert_raise ArgumentError,
                   "server Support.Servers.Scoped declares an authorization block, " <>
                     "its opts must set :resource_url",
                   fn -> Utils.start_runtime(config) end
    end

    test "raises for a transport that is neither :http nor :stdio" do
      config = %{transport: :tcp, servers: [Servers.Default]}

      assert_raise ArgumentError,
                   "transport must be :http or :stdio, got: :tcp",
                   fn -> Utils.start_runtime(config) end
    end

    test "checks :allowed_origins for :stdio when given" do
      config = %{transport: :stdio, servers: [Servers.Default], allowed_origins: "x"}

      assert_raise ArgumentError,
                   ~s{allowed_origins must be a list, got: "x"},
                   fn -> Utils.start_runtime(config) end
    end
  end

  describe "start_link/1 session snapshot" do
    @resource_url "https://mcp.example.com/mcp"

    test "raises when the snapshot module is not a loaded module" do
      config = %{
        servers: [{Servers.Default, %{session_snapshot: NoSuchSnapshot}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "server Support.Servers.Default: the session snapshot module NoSuchSnapshot " <>
                     "must export save/3, load/2, delete/2",
                   fn -> Utils.start_runtime(config) end
    end

    test "raises when the snapshot module misses a function" do
      config = %{
        servers: [
          {Servers.Authorized, %{resource_url: @resource_url, session_snapshot: Enum}}
        ],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "server Support.Servers.Authorized: the session snapshot module Enum " <>
                     "must export save/3, load/2, delete/2",
                   fn -> Utils.start_runtime(config) end
    end

    test "the default snapshot module is OzMcp.Session.Snapshot.None" do
      {:ok, _pid} =
        Utils.start_runtime(%{servers: [Servers.Default], allowed_origins: []})

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, config} = OzMcp.Instance.config(Servers.Default)
      assert config.opts.session_snapshot == OzMcp.Session.Snapshot.None
    end
  end

  describe "start_link/1 required functions of the stores" do
    @resource_url "https://mcp.example.com/mcp"

    test "raises when the task store misses a function" do
      config = %{
        servers: [{Servers.Default, %{task_store: Support.TasksStores.NoPage}}],
        allowed_origins: []
      }

      assert_raise ArgumentError,
                   "server Support.Servers.Default: the task store Support.TasksStores.NoPage " <>
                     "must export the index callbacks all together or not at all, " <>
                     "missing: page/4",
                   fn -> Utils.start_runtime(config) end
    end

    test "a task store that has the required callbacks boots" do
      config = %{
        servers: [{Servers.TasksTest, %{task_store: Support.TasksStores.BehaviourOnly}}],
        allowed_origins: []
      }

      {:ok, _pid} = Utils.start_runtime(config)
      on_exit(fn -> Utils.stop_runtime() end)

      instance = Servers.TasksTest
      session_id = Utils.create_session(instance, initialized: true)

      assert {:ok, %OzMcp.Structs.Task{} = task} =
               OzMcp.Tasks.create(instance, %{
                 session_id: session_id,
                 tool: {Support.Entities.Tools.TaskImmediateTest, "task_immediate"},
                 request: %{"name" => "task_immediate", "arguments" => %{}}
               })

      assert {:ok, {:ok, _}} =
               OzMcp.Tasks.await(instance, Utils.owner(session_id), task.taskId, 5_000)

      assert {:ok, %{status: :completed}} =
               OzMcp.Tasks.get(instance, Utils.owner(session_id), task.taskId)
    end

    test "a task store with the required callbacks gets the index of the facade" do
      config = %{
        servers: [{Servers.TasksTest, %{task_store: Support.TasksStores.BehaviourOnly}}],
        allowed_origins: []
      }

      {:ok, _pid} = Utils.start_runtime(config)
      on_exit(fn -> Utils.stop_runtime() end)

      instance = Servers.TasksTest

      assert :ets.whereis(OzMcp.Tasks.Index.index_table(instance)) != :undefined
      assert :ets.whereis(OzMcp.Tasks.Index.expiry_table(instance)) != :undefined
      assert :ets.whereis(OzMcp.Tasks.Index.counters_table(instance)) != :undefined
    end
  end

  describe "start_link/1 required scopes of the DSL" do
    @resource_url "https://mcp.example.com/mcp"

    test "raises when an open server has a DSL module that requires scopes" do
      server =
        module "OpenWithScopes" do
          tools do
            tool Support.Entities.Tools.ScopedTest
          end
        end
        |> compile()

      assert_raise ArgumentError,
                   "server #{inspect(server)} declares no authorization block, " <>
                     ~S(but its entities require the scopes ["admin", "files:write"]. ) <>
                     "Add an authorization block or remove required_scopes",
                   fn ->
                     Utils.start_runtime(%{servers: [server], allowed_origins: []})
                   end
    end

    test "a protected server with a DSL module that requires scopes boots" do
      server =
        module "ProtectedWithScopes" do
          tools do
            tool Support.Entities.Tools.ScopedTest
          end

          authorization do
            verifier(Support.Auth.Default)
            authorization_servers(["https://auth.example.com"])
          end
        end
        |> compile()

      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{server, %{resource_url: @resource_url}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, _config} = OzMcp.Instance.config(server)
    end

    test "an open server whose modules use dsl?: false boots" do
      {:ok, _pid} =
        Utils.start_runtime(%{servers: [Servers.Default], allowed_origins: []})

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, _config} = OzMcp.Instance.config(Servers.Default)
    end

    test "raises when an open server has a map tool that requires scopes" do
      server = map_scoped_server(["tools:write"])

      assert_raise ArgumentError,
                   ~r/declares no authorization block, but its entities require the scopes \["tools:write"\]/,
                   fn ->
                     Utils.start_runtime(%{servers: [server], allowed_origins: []})
                   end
    end

    test "raises when a map tool carries a bad required_scopes" do
      for bad <- [[], "a"] do
        server = map_scoped_server(bad)

        assert_raise ArgumentError, ~r/'required_scopes'/, fn ->
          Utils.start_runtime(%{servers: [server], allowed_origins: []})
        end
      end
    end

    test "an explicit scopes_supported that lacks a required scope still boots" do
      server =
        module "ScopeNotInList" do
          tools do
            tool Support.Entities.Tools.ScopedTest
          end

          authorization do
            verifier(Support.Auth.Default)
            authorization_servers(["https://auth.example.com"])
            scopes_supported(["files:write"])
          end
        end
        |> compile()

      {:ok, _pid} =
        Utils.start_runtime(%{
          servers: [{server, %{resource_url: @resource_url}}],
          allowed_origins: []
        })

      on_exit(fn -> Utils.stop_runtime() end)

      assert {:ok, _config} = OzMcp.Instance.config(server)
    end
  end

  # A static tool module whose list returns a map with the given scopes
  # and a server that holds the module. The module defines no constant.
  #
  defp map_scoped_server(scopes) do
    code =
      quote do
        def list do
          [
            %{
              "name" => "scoped_map",
              "description" => "A map tool with scopes",
              "inputSchema" => %{"type" => "object"},
              "required_scopes" => unquote(scopes)
            }
          ]
        end

        def call(_ctx, _params), do: {:ok, %{"content" => []}}
      end

    tool_mod =
      Support.Factories.Tool.module("ConfigMapScopedTool", _dsl_: false, _code_: code)
      |> Support.Factories.Tool.compile()

    exprs = [Support.Factories.Server.__tools__([], [Support.Factories.Server.tool(tool_mod)])]

    "ConfigMapScopes"
    |> Support.Factories.Server.__module__([_tools_: :_none_], exprs)
    |> Support.Factories.Server.compile()
  end
end
