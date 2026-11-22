defmodule OzMcp.Transport.Stdio.ConsoleTest do
  #
  # Sync: the tests change the configuration of the default logger handler.
  #
  use ExUnit.Case, async: false

  alias OzMcp.Transport.Stdio.Console

  # These tests change the configuration of the default logger handler:
  # log capture must stay off for them and each test restores what it
  # changed.
  #
  @moduletag capture_log: false

  setup do
    original =
      case :logger.get_handler_config(:default) do
        {:ok, config} -> config
        _ -> nil
      end

    on_exit(fn -> restore_default_handler(original) end)
    :ok
  end

  describe "reader/1 and writer/1" do
    test "read one line per call, give :eof at the end and write" do
      {:ok, device} = StringIO.open("one\ntwo\n")

      reader = Console.reader(device)
      assert {:ok, "one\n"} = reader.()
      assert {:ok, "two\n"} = reader.()
      assert :eof = reader.()

      writer = Console.writer(device)
      assert :ok = writer.("hello ")
      assert :ok = writer.(["world", ?\n])
      assert "hello world\n" = StringIO.flush(device)

      StringIO.close(device)
    end

    test "writer/1 gives {:error, reason} when the device is gone" do
      {:ok, device} = StringIO.open("x")
      dead = StringIO.close(device)

      assert {:error, _reason} = Console.writer(dead).("data")
    end
  end

  describe "redirect_logger/0" do
    test "moves the default handler to stderr and keeps its settings" do
      {:ok, before} = :logger.get_handler_config(:default)

      assert :ok = Console.redirect_logger()

      {:ok, after_first} = :logger.get_handler_config(:default)
      assert after_first.config.type == :standard_error
      assert after_first.level == before.level
      assert after_first.formatter == before.formatter
      assert after_first.filters == before.filters
      assert after_first.filter_default == before.filter_default

      # A second call reconfigures the handler again without an error.
      #
      assert :ok = Console.redirect_logger()

      assert {:ok, %{config: %{type: :standard_error}}} = :logger.get_handler_config(:default)
    end

    test "does nothing when there is no default handler" do
      {:ok, saved} = :logger.get_handler_config(:default)
      _ = :logger.remove_handler(:default)

      assert :ok = Console.redirect_logger()
      assert match?({:error, _}, :logger.get_handler_config(:default))

      restore_default_handler(saved)
    end
  end

  defp restore_default_handler(nil) do
    _ = :logger.remove_handler(:default)
    :ok
  end

  defp restore_default_handler(config) do
    _ = :logger.remove_handler(:default)

    _ =
      :logger.add_handler(:default, config.module, %{
        config: config.config,
        level: config.level,
        formatter: config.formatter,
        filters: config.filters,
        filter_default: config.filter_default
      })

    :ok
  end
end
