defmodule Visor.UsageTest do
  use ExUnit.Case, async: true

  alias Visor.Usage

  test "reads a provider's usage map, leaving out what it didn't report" do
    raw = %{
      "prompt_tokens" => 100,
      "prompt_cache_hit_tokens" => 60,
      "prompt_cache_miss_tokens" => 40,
      "completion_tokens" => 20,
      "completion_tokens_details" => %{"reasoning_tokens" => 5}
    }

    assert %Usage{prompt: 100, cached: 60, uncached: 40, completion: 20, reasoning: 5} =
             Usage.from(raw)

    assert %Usage{prompt: 7, cached: nil, reasoning: nil} = Usage.from(%{"prompt_tokens" => 7})
    assert Usage.from(nil) == nil
  end

  test "measures the context" do
    a = Usage.from(%{"prompt_tokens" => 100, "completion_tokens" => 20})

    assert Usage.context(a) == 120
    assert Usage.context(Usage.from(%{"prompt_tokens" => 1})) == nil
  end
end
