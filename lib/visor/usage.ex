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

  @doc """
  The share of the prompt read from the provider's cache, as a whole
  percent: nil when the provider didn't report both its cache hits and
  misses. An unreported figure is unknown, never a 0% hit (pi-fabric's
  rule); a reported miss is a measured 0.
  """
  def hit_share(%__MODULE__{cached: hit, uncached: miss})
      when is_integer(hit) and is_integer(miss) and hit + miss > 0,
      do: round(hit * 100 / (hit + miss))

  def hit_share(_usage), do: nil

  @doc "The tokens the conversation holds after this call, or nil when unknown."
  def context(%__MODULE__{prompt: prompt, completion: completion})
      when is_integer(prompt) and is_integer(completion),
      do: prompt + completion

  def context(_usage), do: nil

  defp whole(n) when is_integer(n), do: n
  defp whole(_other), do: nil
end
