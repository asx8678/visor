defmodule Visor.Model.DemoTest do
  use ExUnit.Case, async: true

  alias Visor.Model.Demo

  defp user(text), do: %{"role" => "user", "content" => text}
  defp calls(ids), do: %{"role" => "assistant", "tool_calls" => Enum.map(ids, &%{"id" => &1})}
  defp result(id), do: %{"role" => "tool", "tool_call_id" => id, "content" => "ok"}

  test "accepts tool calls answered in full before the next message" do
    assert Demo.invalid([user("a"), calls(["1", "2"]), result("2"), result("1"), user("b")]) ==
             nil
  end

  test "refuses tool calls left unanswered" do
    assert Demo.invalid([user("a"), calls(["1"])]) =~ "have no tool messages"

    assert Demo.invalid([user("a"), calls(["1", "2"]), result("1"), user("b")]) =~
             "must be answered"
  end

  test "refuses a tool message without its call" do
    assert Demo.invalid([user("a"), result("1")]) =~ "must answer a tool call"
    assert Demo.invalid([user("a"), calls(["1"]), result("1"), result("1")]) =~ "must answer"
  end

  test "returns the client's error for a refused request" do
    request = %{messages: [user("a"), calls(["1"]), user("b")]}
    assert {:error, "DeepSeek returned HTTP 400. " <> _} = Demo.stream(request, fn _ -> :ok end)
  end
end
