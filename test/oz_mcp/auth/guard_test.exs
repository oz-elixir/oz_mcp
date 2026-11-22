defmodule OzMcp.Auth.GuardTest do
  use ExUnit.Case, async: true

  alias OzMcp.Auth.Guard
  alias OzMcp.Auth.Principal
  alias Support.Helpers.Utils

  describe "call/2" do
    test "returns the value of the callback wrapped in ok" do
      assert Guard.call("test/0", fn -> {:done, 1} end) == {:ok, {:done, 1}}
    end

    test "a callback that returns :failed is a value, not a failure" do
      assert Guard.call("test/0", fn -> :failed end) == {:ok, :failed}
    end

    test "a raise logs one line at level :error with the type only" do
      log =
        Utils.capture_log([level: :error], fn ->
          assert Guard.call("test/0", fn -> raise "failure with SECRET-TOKEN" end) == :failed
        end)

      refute log =~ "SECRET-TOKEN"
      assert log =~ "test/0 failed: raised RuntimeError"

      assert log |> String.split("\n") |> Enum.count(&String.contains?(&1, "[error]")) == 1
    end

    test "the text of a raise appears only at level :debug" do
      error_log =
        Utils.capture_log([level: :error], fn ->
          assert Guard.call("test/0", fn -> raise "failure with SECRET-TOKEN" end) == :failed
        end)

      refute error_log =~ "failure with SECRET-TOKEN"

      debug_log =
        Utils.capture_log([level: :debug], fn ->
          assert Guard.call("test/0", fn -> raise "failure with SECRET-TOKEN" end) == :failed
        end)

      assert debug_log =~ "test/0 failure text: failure with SECRET-TOKEN"
    end

    test "the stacktrace of a clause error holds the function and the arity, no arguments" do
      log =
        Utils.capture_log([level: :error], fn ->
          assert Guard.call("test/0", fn -> leak_clause("SECRET-TOKEN", 1) end) == :failed
        end)

      assert log =~ "FunctionClauseError"
      assert log =~ "leak_clause/2"
      refute log =~ "SECRET-TOKEN"
    end

    test "a throw logs no value" do
      log =
        Utils.capture_log([level: :error], fn ->
          assert Guard.call("test/0", fn -> throw({:bad, "SECRET-TOKEN"}) end) == :failed
        end)

      refute log =~ "SECRET-TOKEN"
      assert log =~ "test/0 failed: throw (the value is not logged)"

      assert log |> String.split("\n") |> Enum.count(&String.contains?(&1, "[error]")) == 1
    end

    test "an exit with an atom reason logs the atom" do
      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          assert Guard.call("test/0", fn -> exit(:shutdown) end) == :failed
        end)

      assert log =~ "test/0 failed: exit :shutdown"
    end

    test "an exit with a tuple reason logs only the tag" do
      log =
        Utils.capture_log([level: :error], fn ->
          assert Guard.call("test/0", fn -> exit({:timeout, "SECRET-TOKEN"}) end) == :failed
        end)

      refute log =~ "SECRET-TOKEN"
      assert log =~ "test/0 failed: exit :timeout"
    end

    test "an exit whose reason is neither an atom nor a tuple logs no reason" do
      log =
        Utils.capture_log([level: :error], fn ->
          assert Guard.call("test/0", fn -> exit("SECRET-TOKEN") end) == :failed
        end)

      refute log =~ "SECRET-TOKEN"
      assert log =~ "test/0 failed: exit (reason not logged)"
    end
  end

  describe "shape/1" do
    test "describes an atom by its name" do
      assert Guard.shape(:failed) == ":failed"
    end

    test "describes a tuple by its tag, its size and the type of the second element" do
      assert Guard.shape({:error, {:bad, "SECRET-TOKEN"}}) ==
               "tuple :error of size 2 (second element: tuple of size 2)"
    end

    test "describes a tuple whose first element is not an atom by its size" do
      assert Guard.shape({"SECRET-TOKEN", 1}) == "tuple of size 2"
    end

    test "describes the other types with no content" do
      assert Guard.shape(%{"token" => "SECRET-TOKEN"}) == "map"
      assert Guard.shape("SECRET-TOKEN") == "binary"
      assert Guard.shape([1, 2]) == "list"
      assert Guard.shape(42) == "term"
      assert Guard.shape(:ok) == ":ok"
    end

    test "names a struct by its module" do
      assert Guard.shape(%URI{}) == "struct URI"
      refute Guard.shape(%URI{}) =~ "SECRET-TOKEN"
    end

    test "describes a principal with a subject by its name" do
      assert Guard.shape(%Principal{subject: "alice"}) == "principal"
      assert Guard.shape(%Principal{subject: "SECRET-TOKEN"}) == "principal"
    end

    test "names a principal with an empty or non-binary subject" do
      assert Guard.shape(%Principal{subject: ""}) ==
               "principal with an empty or non-binary subject"

      assert Guard.shape(%Principal{subject: 123}) ==
               "principal with an empty or non-binary subject"
    end

    test "the second element of a tuple is named by its type, never its content" do
      assert Guard.shape({:ok, %Principal{subject: nil}}) ==
               "tuple :ok of size 2 (second element: principal with an empty or non-binary subject)"

      refute Guard.shape({:ok, "SECRET-TOKEN"}) =~ "SECRET-TOKEN"
      assert Guard.shape({:ok, "SECRET-TOKEN"}) == "tuple :ok of size 2 (second element: binary)"

      assert Guard.shape({:ok, nil}) == "tuple :ok of size 2 (second element: nil)"

      assert Guard.shape({:error, "SECRET-TOKEN"}) ==
               "tuple :error of size 2 (second element: binary)"

      assert Guard.shape({:error, 401}) == "tuple :error of size 2 (second element: integer)"
    end
  end

  # A clause that never matches: the raise of the failure carries the
  # arguments and with them the marker string.
  #
  defp leak_clause(_token, _count) when false, do: :ok
end
