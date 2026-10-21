defmodule Visor.Usage do
  @moduledoc """
  A model call's token usage, read from the usage map the provider
  returned. That map uses DeepSeek's names (`Visor.Model.DeepSeek` adds
  them for gateways that use OpenAI's), and it is what the agent's
  `turn_end` event carries and the session log writes as it is, so a log
  line's `usage` reads the same way.

  A field is nil when the provider didn't report it.
  """

  defstruct [:prompt, :cached, :uncached, :completion, :reasoning]

  @type t :: %__MODULE__{
          prompt: non_neg_integer() | nil,
          cached: non_neg_integer() | nil,
          uncached: non_neg_integer() | nil,
          completion: non_neg_integer() | nil,
          reasoning: non_neg_integer() | nil
        }

  @doc "Usage from a provider's usage map (string keys), or nil without one."
  def from(usage) when is_map(usage) do
    details = usage["completion_tokens_details"]

    %__MODULE__{
      prompt: whole(usage["prompt_tokens"]),
      cached: whole(usage["prompt_cache_hit_tokens"]),
      uncached: whole(usage["prompt_cache_miss_tokens"]),
      completion: whole(usage["completion_tokens"]),
      reasoning: if(is_map(details), do: whole(details["reasoning_tokens"]))
    }
  end

  def from(_none), do: nil

  @doc "Usage with every field 0, to add to."
  def zero, do: %__MODULE__{prompt: 0, cached: 0, uncached: 0, completion: 0, reasoning: 0}

  @doc "The sum of two usages, counting a missing field as 0."
  def add(sum, nil), do: sum

  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    plus = fn x, y -> (x || 0) + (y || 0) end

    %__MODULE__{
      prompt: plus.(a.prompt, b.prompt),
      cached: plus.(a.cached, b.cached),
      uncached: plus.(a.uncached, b.uncached),
      completion: plus.(a.completion, b.completion),
      reasoning: plus.(a.reasoning, b.reasoning)
    }
  end

  @doc "The tokens the conversation holds after this call, or nil when unknown."
  def context(%__MODULE__{prompt: prompt, completion: completion})
      when is_integer(prompt) and is_integer(completion),
      do: prompt + completion

  def context(_usage), do: nil

  defp whole(n) when is_integer(n), do: n
  defp whole(_other), do: nil
end
