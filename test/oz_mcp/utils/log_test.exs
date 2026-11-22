defmodule OzMcp.Utils.LogTest do
  use ExUnit.Case, async: true

  alias OzMcp.Utils.Log
  alias Support.Helpers.Utils

  describe "describe/3" do
    test "a raise is named by the module of the exception" do
      log =
        Utils.capture_log(fn ->
          assert Log.describe(:error, %RuntimeError{message: "SECRET-TOKEN"}, []) ==
                   "raised RuntimeError"
        end)

      # describe/3 is called directly here: the marker check targets the
      # return value, not the log.
      #
      refute Log.describe(:error, %RuntimeError{message: "SECRET-TOKEN"}, []) =~
               "SECRET-TOKEN"

      refute log =~ "SECRET-TOKEN"
    end

    test "a throw names no value" do
      assert Log.describe(:throw, {:bad, "SECRET-TOKEN"}, []) ==
               "throw (the value is not logged)"
    end

    test "an exit with an atom reason logs the atom" do
      assert Log.describe(:exit, :shutdown, []) == "exit :shutdown"
    end

    test "an exit with a tuple reason logs only the tag" do
      assert Log.describe(:exit, {:timeout, "SECRET-TOKEN"}, []) == "exit :timeout"
    end

    test "an exit whose reason is neither an atom nor a tuple logs no reason" do
      assert Log.describe(:exit, "SECRET-TOKEN", []) == "exit (reason not logged)"
    end

    test "an Erlang error is normalized to its Elixir exception module" do
      assert Log.describe(:error, :badarg, []) == "raised ArgumentError"
    end

    test "a badmatch reason is named by its exception module, never its value" do
      result = Log.describe(:error, {:badmatch, "SECRET-TOKEN"}, [])

      assert result == "raised MatchError"
      refute result =~ "SECRET-TOKEN"
    end

    test "a reason of another shape does not raise and names no content" do
      assert Log.describe(:error, {:tuple, :of, :terms}, []) == "raised ErlangError"

      assert Log.describe(:error, "plain reason", []) == "raised ErlangError"

      assert Log.describe(:error, nil, []) == "raised ErlangError"
    end
  end

  describe "format_stacktrace/1" do
    test "a clause error frame holds the function and the arity, no arguments" do
      stacktrace =
        try do
          leak_clause("SECRET-TOKEN", 1)
        rescue
          FunctionClauseError -> __STACKTRACE__
        end

      formatted = Log.format_stacktrace(stacktrace)

      assert formatted =~ "leak_clause/2"
      refute formatted =~ "SECRET-TOKEN"
    end

    test "keeps at most 10 frames" do
      frame = {:Foo, :bar, [1, 2, 3], [file: ~c"foo.ex", line: 1]}
      formatted = Log.format_stacktrace(List.duplicate(frame, 40))

      assert length(String.split(formatted, "foo.ex")) <= 40
      assert formatted =~ "Foo.bar/3"
      refute formatted =~ "[1, 2, 3]"
    end

    test "a three-element frame is formatted with its arity" do
      formatted = Log.format_stacktrace([{Foo, :baz, [:a, :b]}])

      assert formatted =~ "Foo.baz/2"
    end
  end

  describe "banner/3" do
    test "holds the full text of the failure" do
      assert Log.banner(:error, %RuntimeError{message: "boom from config"}, []) =~
               "boom from config"
    end

    test "a throw holds the thrown value" do
      assert Log.banner(:throw, "SECRET-TOKEN", []) =~ "SECRET-TOKEN"
    end

    test "an exit holds the reason" do
      assert Log.banner(:exit, {:x, "SECRET-TOKEN"}, []) =~ "SECRET-TOKEN"
    end
  end

  # A clause that never matches: the raise of the failure carries the
  # arguments and with them the marker string.
  #
  defp leak_clause(_token, _count) when false, do: :ok
end
