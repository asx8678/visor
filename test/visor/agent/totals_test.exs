defmodule Visor.Agent.TotalsTest do
  use ExUnit.Case, async: true

  alias Visor.Agent.Totals

  test "counts a prompt's events" do
    usage = %{
      "prompt_tokens" => 100,
      "prompt_cache_hit_tokens" => 60,
      "prompt_cache_miss_tokens" => 40,
      "completion_tokens" => 20
    }

    totals =
      Enum.reduce(
        [
          {:user, "hi"},
          {:turn_start, %{n: 1}},
          {:turn_end, %{usage: usage, ms: 900}},
          {:tool_start, %{id: "c1"}},
          {:code_call, "c1", %{status: :running}},
          {:code_call, "c1", %{status: :ok}},
          {:code_call, "c1", %{status: :error}},
          {:tool_end, %{status: :error, ms: 50}},
          {:turn_start, %{n: 2}},
          {:turn_end, %{usage: nil}},
          {:note, :error, "boom"}
        ],
        %Totals{},
        &Totals.add(&2, &1)
      )

    assert %Totals{
             turns: 2,
             tool_calls: 1,
             tool_errors: 1,
             v_calls: 2,
             v_errors: 1,
             errors: 1,
             prompt_tokens: 100,
             cached_tokens: 60,
             uncached_tokens: 40,
             completion_tokens: 20,
             reasoning_tokens: 0,
             model_ms: 900,
             tool_ms: 50
           } = totals
  end

  test "keeps the prompt tokens without cache figures apart" do
    measured = %{
      "prompt_tokens" => 100,
      "prompt_cache_hit_tokens" => 90,
      "prompt_cache_miss_tokens" => 10
    }

    totals =
      Enum.reduce(
        [{:turn_end, %{usage: measured}}, {:turn_end, %{usage: %{"prompt_tokens" => 500}}}],
        %Totals{},
        &Totals.add(&2, &1)
      )

    assert %{prompt_tokens: 600, cached_tokens: 90, uncached_tokens: 10, unmeasured_tokens: 500} =
             totals
  end

  test "counts reviews and their tokens apart from the agent's" do
    usage = %{"prompt_tokens" => 300, "completion_tokens" => 20}
    totals = Totals.add(%Totals{}, {:review, %{usage: usage}})
    assert %{reviews: 1, review_tokens: 320, prompt_tokens: 0} = totals
  end
end
