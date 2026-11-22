defmodule OzMcp.Utils.GeneratorTest do
  use ExUnit.Case, async: true
  alias OzMcp.Utils.Generator

  describe "session_id/0" do
    test "returns a 40 char alphanumeric string" do
      session_id = Generator.session_id()

      assert is_binary(session_id)
      assert String.length(session_id) == 40
      assert String.match?(session_id, ~r/^[0-9a-zA-Z]+$/)
    end
  end

  describe "get_stream_id/0" do
    test "starts with g., holds no colon and is alphanumeric" do
      for _ <- 1..200 do
        id = Generator.get_stream_id()

        assert String.starts_with?(id, "g.")
        refute String.contains?(id, ":")
        assert String.length(id) == 12
        assert String.match?(id, ~r/^g\.[0-9a-zA-Z]+$/)
      end
    end

    test "is unique" do
      ids = for _ <- 1..200, do: Generator.get_stream_id()
      assert length(Enum.uniq(ids)) == 200
    end
  end

  describe "stream_id/0" do
    test "is a short URL-safe alphanumeric string, without the id separator" do
      stream_id = Generator.stream_id()

      assert String.length(stream_id) == 10
      assert String.match?(stream_id, ~r/^[0-9a-zA-Z]+$/)
    end

    test "is unique" do
      ids = for _ <- 1..200, do: Generator.stream_id()
      assert length(Enum.uniq(ids)) == 200
    end
  end

  describe "task_id/0" do
    test "returns a 32 char alphanumeric string" do
      task_id = Generator.task_id()

      assert is_binary(task_id)
      assert String.length(task_id) == 32
      assert String.match?(task_id, ~r/^[0-9a-zA-Z]+$/)
    end

    test "is unique over 10k draws" do
      ids = for _ <- 1..10_000, do: Generator.task_id()

      assert length(Enum.uniq(ids)) == 10_000
    end
  end

  describe "request_id/0" do
    test "is a 20 character alphanumeric string" do
      request_id = Generator.request_id()

      assert is_binary(request_id)
      assert String.length(request_id) == 20
      assert String.match?(request_id, ~r/^[0-9a-zA-Z]+$/)
    end

    test "is unique over 10k draws" do
      ids = for _ <- 1..10_000, do: Generator.request_id()

      assert length(Enum.uniq(ids)) == 10_000
    end
  end

  # The id of a request of a task has the form "t.<task_id>.<n>" and the
  # routing of the answer splits the rest on the dot: the ids of the
  # generator must never hold one.
  #
  describe "the ids and the separator of the id of a request of a task" do
    test "request_id/0 and task_id/0 never hold a dot" do
      for _ <- 1..1_000 do
        refute String.contains?(Generator.request_id(), ".")
        refute String.contains?(Generator.task_id(), ".")
      end
    end
  end

  describe "elicitation_id/0" do
    test "is a 20 character alphanumeric string" do
      elicitation_id = Generator.elicitation_id()

      assert String.length(elicitation_id) == 20
      assert String.match?(elicitation_id, ~r/^[0-9a-zA-Z]+$/)
    end

    test "is unique over 1k draws" do
      ids = for _ <- 1..1_000, do: Generator.elicitation_id()

      assert length(Enum.uniq(ids)) == 1_000
    end
  end
end
