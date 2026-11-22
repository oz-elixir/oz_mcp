defmodule Mix.Tasks.OzMcpStdioArgsTest do
  use ExUnit.Case, async: true
  alias Support.Servers

  describe "parse_args!/1" do
    test "accepts one name and the flags" do
      assert {"Support.Servers.Outbound", [start_app: true, log_level: "error"]} =
               Mix.Tasks.OzMcp.Stdio.parse_args!([
                 "Support.Servers.Outbound",
                 "--start-app",
                 "--log-level",
                 "error"
               ])
    end

    test "accepts --drain-timeout" do
      assert {"Support.Servers.Outbound", [drain_timeout: 250]} =
               Mix.Tasks.OzMcp.Stdio.parse_args!([
                 "Support.Servers.Outbound",
                 "--drain-timeout",
                 "250"
               ])
    end

    test "accepts --max-queue" do
      assert {"Support.Servers.Outbound", [max_queue: 500]} =
               Mix.Tasks.OzMcp.Stdio.parse_args!([
                 "Support.Servers.Outbound",
                 "--max-queue",
                 "500"
               ])
    end

    test "a zero or negative --max-queue raises" do
      assert_raise Mix.Error, ~r/invalid max queue/, fn ->
        Mix.Tasks.OzMcp.Stdio.parse_args!(["Support.Servers.Outbound", "--max-queue=0"])
      end

      assert_raise Mix.Error, ~r/invalid max queue/, fn ->
        Mix.Tasks.OzMcp.Stdio.parse_args!(["Support.Servers.Outbound", "--max-queue=-5"])
      end
    end

    test "a negative or non-integer --drain-timeout raises" do
      assert_raise Mix.Error, ~r/invalid drain timeout/, fn ->
        Mix.Tasks.OzMcp.Stdio.parse_args!(["Support.Servers.Outbound", "--drain-timeout=-5"])
      end

      assert_raise OptionParser.ParseError, fn ->
        Mix.Tasks.OzMcp.Stdio.parse_args!(["Support.Servers.Outbound", "--drain-timeout", "abc"])
      end
    end

    test "an unknown --log-level raises before the application starts" do
      assert_raise Mix.Error, ~r/invalid log level: bogus/, fn ->
        Mix.Tasks.OzMcp.Stdio.parse_args!(["Support.Servers.Outbound", "--log-level", "bogus"])
      end
    end

    test "a name with no flag" do
      assert {"Support.Servers.Outbound", []} =
               Mix.Tasks.OzMcp.Stdio.parse_args!(["Support.Servers.Outbound"])
    end

    test "with no argument raises with the usage text" do
      assert_raise Mix.Error, ~r/usage: mix oz_mcp\.stdio/, fn ->
        Mix.Tasks.OzMcp.Stdio.parse_args!([])
      end
    end

    test "with two arguments raises with the usage text" do
      assert_raise Mix.Error, ~r/usage: mix oz_mcp\.stdio/, fn ->
        Mix.Tasks.OzMcp.Stdio.parse_args!(["One", "Two"])
      end
    end
  end

  describe "fetch_server!/1" do
    test "returns the module of a server" do
      assert Mix.Tasks.OzMcp.Stdio.fetch_server!("Support.Servers.Default") ==
               Servers.Default
    end

    test "a name that is not a module raises with a clear text" do
      assert_raise Mix.Error, "NoSuchModule is not an OzMcp server module", fn ->
        Mix.Tasks.OzMcp.Stdio.fetch_server!("NoSuchModule")
      end
    end

    test "a module that is not a server raises with a clear text" do
      assert_raise Mix.Error, "Enum is not an OzMcp server module", fn ->
        Mix.Tasks.OzMcp.Stdio.fetch_server!("Enum")
      end
    end
  end

  describe "stop_message/1" do
    test "a lost session tells the operator to start the server again" do
      message = Mix.Tasks.OzMcp.Stdio.stop_message({:shutdown, :session_lost})

      assert message =~ ~r/session is lost/
      assert message =~ ~r/start the server again/
    end

    test "a session that was never initialized names the option" do
      message = Mix.Tasks.OzMcp.Stdio.stop_message({:shutdown, :init_timeout})

      assert message =~ ~r/notifications\/initialized/
      assert message =~ ~r/session_init_timeout_ms/
    end

    test "an overflow of the output queue names the flag" do
      message = Mix.Tasks.OzMcp.Stdio.stop_message({:shutdown, {:output_overflow, 10_000}})

      assert message =~ ~r/stdout reader is too slow/
      assert message =~ "10000"
      assert message =~ "--max-queue"
    end

    test "any other reason keeps the inspected form" do
      assert Mix.Tasks.OzMcp.Stdio.stop_message({:shutdown, :drained}) ==
               "the stdio transport stopped: {:shutdown, :drained}"

      assert Mix.Tasks.OzMcp.Stdio.stop_message(:boom) == "the stdio transport stopped: :boom"
    end
  end
end
