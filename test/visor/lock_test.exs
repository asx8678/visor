defmodule Visor.LockTest do
  use ExUnit.Case, async: true

  alias Visor.Lock

  # Holds `key` in a process of its own until it gets :release.
  defp holder(key) do
    test = self()

    pid =
      spawn(fn ->
        Lock.hold(key, fn ->
          send(test, {:holding, self()})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:holding, ^pid}, 1_000
    pid
  end

  # Asks for `key` in a process of its own, and reports when it gets it.
  defp waiter(key, name) do
    test = self()
    pid = spawn(fn -> Lock.hold(key, fn -> send(test, {:got, name}) end) end)
    wait_until_queued(key, pid)
    pid
  end

  # Returns once `pid` is waiting for `key`, or fails after 5 s.
  defp wait_until_queued(key, pid, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    waiting =
      case :sys.get_state(Lock) do
        %{^key => {_holder, _ref, waiting}} -> Enum.map(:queue.to_list(waiting), &elem(&1, 0))
        _ -> []
      end

    cond do
      pid in waiting -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("#{inspect(pid)} never waited")
      true -> wait_until_queued(key, pid, deadline)
    end
  end

  test "lets one process hold a key at a time, then the others in the order they asked" do
    key = {:file, make_ref()}
    first = holder(key)
    for name <- [:a, :b, :c], do: waiter(key, name)

    # Another key isn't held up.
    Lock.hold({:file, make_ref()}, fn -> send(self(), :other) end)
    assert_received :other
    refute_received {:got, _}

    send(first, :release)
    assert_receive {:got, :a}, 1_000
    assert_receive {:got, :b}, 1_000
    assert_receive {:got, :c}, 1_000
    refute Map.has_key?(:sys.get_state(Lock), key)
  end

  test "frees a key when its holder exits, and skips a waiter that exited" do
    key = {:check, make_ref()}
    first = holder(key)
    gone = waiter(key, :gone)
    waiter(key, :next)

    Process.exit(gone, :kill)
    Process.exit(first, :kill)
    assert_receive {:got, :next}, 1_000
    refute_received {:got, :gone}
  end

  test "frees a key whose holder exited unseen" do
    key = {:file, make_ref()}
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

    # As if the holder's :DOWN was dropped while the server recompiled.
    :sys.replace_state(Lock, &Map.put(&1, key, {dead, make_ref(), :queue.new()}))
    assert Lock.hold(key, fn -> :mine end) == :mine
  end

  test "frees a key when the function raises" do
    key = {:file, make_ref()}
    assert_raise RuntimeError, fn -> Lock.hold(key, fn -> raise "boom" end) end
    assert Lock.hold(key, fn -> :again end) == :again
  end
end
