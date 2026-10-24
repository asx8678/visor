defmodule Visor.CompactionTest do
  use ExUnit.Case, async: true

  alias Visor.{Compaction, Limits}

  # Every request also sends the system prompt and the tools: about this many
  # estimated tokens.
  @fixed 1_000

  defp opts(extra), do: Keyword.merge([fixed: @fixed, scale: 1.0, threshold: 10_000], extra)

  defp user(text), do: %{"role" => "user", "content" => text}

  defp answer(text),
    do: %{"role" => "assistant", "content" => text, "reasoning_content" => "PRIVATE REASONING"}

  defp calls(ids) do
    %{
      "role" => "assistant",
      "content" => "",
      "reasoning_content" => "PRIVATE REASONING",
      "tool_calls" =>
        for id <- ids do
          code = ~s|V.read("lib/#{id}.ex")|

          %{
            "id" => id,
            "type" => "function",
            "function" => %{"name" => "elixir", "arguments" => Jason.encode!(%{code: code})}
          }
        end
    }
  end

  defp result(id, text), do: %{"role" => "tool", "tool_call_id" => id, "content" => text}

  # `prompts` prompts, each reading two files in one batch.
  defp conversation(prompts) do
    Enum.flat_map(1..prompts, fn n ->
      [
        user("prompt #{n}"),
        calls(["a#{n}", "b#{n}"]),
        result("a#{n}", "ok: 1 call\n=> text, 4,000 bytes:\n" <> String.duplicate("x", 4_000)),
        result("b#{n}", "ok: 1 call\n=> :ok"),
        answer("answer #{n}")
      ]
    end)
  end

  defp facts(prompts) do
    for n <- 1..prompts, id <- ["a#{n}", "b#{n}"], into: %{} do
      read = %{name: :read, text: ~s|read("lib/#{id}.ex")|, status: :ok, path: "lib/#{id}.ex"}
      {id, %{status: :ok, calls: [read]}}
    end
  end

  test "keeps a conversation under its threshold as it is" do
    assert :keep = Compaction.compact(conversation(2), opts(threshold: 1_000_000))
  end

  test "summarizes what came before a cut that keeps the recent part and every batch whole" do
    messages = conversation(20)

    assert {:ok, %{from: from, summary: summary}, info} =
             Compaction.compact(messages, opts(facts: facts(20)))

    assert Enum.at(messages, from)["role"] in ["user", "assistant"]
    assert info.tokens_after < info.tokens_before
    assert info.summarized == from

    # No tool result is kept without the call that asked for it.
    kept = Enum.drop(messages, from)
    called = for %{"tool_calls" => calls} <- kept, %{"id" => id} <- calls, do: id
    answered = for %{"role" => "tool", "tool_call_id" => id} <- kept, do: id
    assert answered -- called == []

    assert summary =~ "[Visor compaction] Messages 1-#{from} of this conversation"
    assert summary =~ "[Recent user directions and discussion]"
    assert summary =~ "Read: lib/"
    assert summary =~ "V.recall("
  end

  test "compiles the same summary from the same conversation, and another from a longer one" do
    messages = conversation(20)
    first = Compaction.compact(messages, opts(facts: facts(20)))
    assert first == Compaction.compact(messages, opts(facts: facts(20)))

    longer = Compaction.compact(conversation(21), opts(facts: facts(21)))
    assert {:ok, %{summary: a}, _info} = first
    assert {:ok, %{summary: b}, _info} = longer
    assert a != b
  end

  test "leaves reasoning out and bounds the summary" do
    assert {:ok, %{summary: summary}, _info} =
             Compaction.compact(conversation(200), opts(facts: facts(200)))

    refute summary =~ "PRIVATE REASONING"
    assert byte_size(summary) <= Limits.summary_bytes()
  end

  test "marks a failure resolved once the same call works" do
    messages = conversation(20)
    read = %{name: :read, text: ~s|read("lib/a1.ex")|, path: "lib/a1.ex"}
    failed = Map.merge(read, %{status: :error, error: "lib/a1.ex does not exist."})
    worked = Map.put(read, :status, :ok)

    facts =
      facts(20)
      |> Map.put("a1", %{status: :error, calls: [failed]})
      |> Map.put("a2", %{status: :ok, calls: [worked]})

    assert {:ok, %{summary: summary}, _info} = Compaction.compact(messages, opts(facts: facts))
    assert summary =~ ~s|V.read("lib/a1.ex"): lib/a1.ex does not exist. [call a1] RESOLVED|
  end

  test "compacts again from the original messages, after the last cut" do
    messages = conversation(20)
    assert {:ok, first, _info} = Compaction.compact(messages, opts(facts: facts(20)))

    # The same conversation, twenty prompts later.
    more = conversation(40)
    assert Enum.take(more, length(messages)) == messages

    assert {:ok, second, _info} =
             Compaction.compact(more, opts(compaction: first, facts: facts(40)))

    assert second.from > first.from
    assert second.summary =~ "[Visor compaction] Messages 1-#{second.from} of this conversation"
  end

  test "keeps everything when no summary would make the context smaller" do
    messages = [user("hi"), answer("hello"), user("again")]
    assert :keep = Compaction.compact(messages, opts(force: true))
  end

  test "puts the summary in the first kept user message, or before an assistant one" do
    messages = [user("one"), answer("two"), user("three"), answer("four")]

    assert [%{"role" => "user", "content" => "S\n\nthree"}, %{"content" => "four"}] =
             Compaction.surface(messages, %{from: 2, summary: "S"})

    assert [%{"role" => "user", "content" => "S"}, %{"content" => "two"} | _] =
             Compaction.surface(messages, %{from: 1, summary: "S"})

    assert [%{"role" => "user", "content" => "S"}] =
             Compaction.surface(messages, %{from: 4, summary: "S"})
  end
end
