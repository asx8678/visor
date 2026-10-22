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
end
