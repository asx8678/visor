defmodule Visor.Agent.Totals do
  @moduledoc """
  What a prompt, or a whole session, used: model calls, tool and `V`
  calls, errors, tokens and time. Built by folding the agent's events
  (`Visor.Agent.Event`) with `add/2`, so the console and the session log
  count the same way.

  The session log writes these fields as they are on its `prompt_end`
  and `summary` lines, which `mix visor.log` reads back.
  """

  alias Visor.Usage

  defstruct turns: 0,
            tool_calls: 0,
            tool_errors: 0,
            v_calls: 0,
            v_errors: 0,
            errors: 0,
            prompt_tokens: 0,
            cached_tokens: 0,
            uncached_tokens: 0,
            # Prompt tokens of calls whose cache figures weren't reported,
            # so the hit share is of the rest.
            unmeasured_tokens: 0,
            completion_tokens: 0,
            reasoning_tokens: 0,
            model_ms: 0,
            tool_ms: 0,
            request_bytes: 0,
            jobs: 0,
            wakes: 0,
            # The reviewer's model calls, and their tokens in and out.
            reviews: 0,
            review_tokens: 0

  @type t :: %__MODULE__{}

  @doc "Counts one event."
  def add(totals, {:turn_start, _info}), do: bump(totals, turns: 1)

  def add(totals, {:turn_end, info}) do
    usage = Usage.from(Map.get(info, :usage)) || %Usage{}

    unmeasured = if Usage.hit_share(usage), do: 0, else: usage.prompt

    bump(totals,
      prompt_tokens: usage.prompt,
      cached_tokens: usage.cached,
      uncached_tokens: usage.uncached,
      unmeasured_tokens: unmeasured,
      completion_tokens: usage.completion,
      reasoning_tokens: usage.reasoning,
      model_ms: Map.get(info, :ms)
    )
  end

  def add(totals, {:tool_start, _call}), do: bump(totals, tool_calls: 1)

  def add(totals, {:tool_end, call}),
    do: bump(totals, tool_errors: error(call.status), tool_ms: Map.get(call, :ms))

  def add(totals, {:code_call, _call_id, %{status: :running}}), do: totals

  def add(totals, {:code_call, _call_id, call}),
    do: bump(totals, v_calls: 1, v_errors: error(call.status))

  def add(totals, {:note, :error, _text}), do: bump(totals, errors: 1)
  def add(totals, {:job_start, _job}), do: bump(totals, jobs: 1)

  # A sub-agent's model calls are this session's spending too.
  def add(totals, {:job_end, %{kind: :agent, totals: %{} = child}}) do
    bump(totals,
      prompt_tokens: child[:prompt_tokens],
      cached_tokens: child[:cached_tokens],
      uncached_tokens: child[:uncached_tokens],
      unmeasured_tokens: child[:unmeasured_tokens],
      completion_tokens: child[:completion_tokens],
      reasoning_tokens: child[:reasoning_tokens],
      model_ms: child[:model_ms]
    )
  end

  def add(totals, {:wake, _text}), do: bump(totals, wakes: 1)

  def add(totals, {:review, info}) do
    usage = Usage.from(Map.get(info, :usage)) || %Usage{}
    bump(totals, reviews: 1, review_tokens: (usage.prompt || 0) + (usage.completion || 0))
  end

  def add(totals, _event), do: totals

  @doc "Adds to fields by name; anything but an integer counts as 0."
  def bump(totals, counts) do
    Enum.reduce(counts, totals, fn
      {key, n}, totals when is_integer(n) -> Map.update!(totals, key, &(&1 + n))
      _missing, totals -> totals
    end)
  end

  @doc "The totals as a plain map, for a log line."
  def to_map(totals), do: Map.from_struct(totals)

  defp error(:error), do: 1
  defp error(_status), do: 0
end
