defmodule Visor.ObserverTest do
  use ExUnit.Case, async: true

  alias Visor.Observer

  test "puts exited children back among the live ones in spawn order" do
    [first, second, third] = for _ <- 1..3, do: spawn(fn -> :ok end)
    live = [{third, %{id: :third}}, {first, %{id: :first}}]
    exited = [{second, %{type: :ghost}}, {third, %{type: :ghost}}]

    # The supervisor still lists the third, so it counts as live.
    assert Observer.with_exited(live, exited) ==
             [{first, %{id: :first}}, {second, %{type: :ghost}}, {third, %{id: :third}}]
  end

  # A process the tree walk found can end before it is traced: a V.all
  # task lives a few milliseconds. Tracing it crashed the observer.
  test "traces the processes it found, skipping one that has ended" do
    session = :trace.session_create(:observer_test, self(), [])
    on_exit(fn -> :trace.session_destroy(session) end)

    ended = spawn(fn -> :ok end)
    ref = Process.monitor(ended)
    assert_receive {:DOWN, ^ref, :process, ^ended, :normal}
    running = spawn(fn -> receive(do: (:stop -> :ok)) end)

    assert Observer.trace(session, [ended, running]) == :ok

    send(running, :stop)
    assert_receive {:trace, ^running, :exit, :normal}
  end
end
