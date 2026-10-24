defmodule Visor.Agent.RepairTest do
  use ExUnit.Case, async: true

  alias Visor.Agent.Repair
  alias Visor.Model.Demo

  defp user(text), do: %{"role" => "user", "content" => text}
  defp calls(ids), do: %{"role" => "assistant", "tool_calls" => Enum.map(ids, &%{"id" => &1})}
  defp result(id, text \\ "ok"), do: %{"role" => "tool", "tool_call_id" => id, "content" => text}

  test "leaves a conversation in order as it is" do
    messages = [user("a"), calls(["1", "2"]), result("1"), result("2"), user("b")]
    assert {^messages, nil} = Repair.messages(messages, %{}, "missing")
  end

  test "answers calls a batch left open, with the results that came in" do
    messages = [user("a"), calls(["1", "2", "3"]), user("b")]
    {repaired, info} = Repair.messages(messages, %{"1" => "done"}, "not run")

    assert info == %{answered: 3, dropped: 0}

    assert repaired == [
             user("a"),
             calls(["1", "2", "3"]),
             result("1", "done"),
             result("2", "not run"),
             result("3", "not run"),
             user("b")
           ]

    assert Demo.invalid(repaired) == nil
  end

  test "answers calls still open at the end" do
    {repaired, %{answered: 1}} = Repair.messages([user("a"), calls(["1"])], %{}, "not run")
    assert List.last(repaired) == result("1", "not run")
  end

  test "keeps the results that arrived and answers only the rest" do
    messages = [user("a"), calls(["1", "2"]), result("2"), user("b")]
    {repaired, info} = Repair.messages(messages, %{}, "not run")

    assert info == %{answered: 1, dropped: 0}
    assert Enum.slice(repaired, 2, 2) == [result("2"), result("1", "not run")]
  end

  test "drops results without their call" do
    messages = [user("a"), result("9"), calls(["1"]), result("1"), result("1")]
    {repaired, info} = Repair.messages(messages, %{}, "not run")

    assert info == %{answered: 0, dropped: 2}
    assert repaired == [user("a"), calls(["1"]), result("1")]
  end
end
