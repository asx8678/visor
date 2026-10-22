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
            completion_tokens: 0,
            reasoning_tokens: 0,
            model_ms: 0,
            tool_ms: 0,
            request_bytes: 0

  @type t :: %__MODULE__{}

  @doc "Counts one event."
  def add(totals, {:turn_start, _info}), do: bump(totals, turns: 1)

  def add(totals, {:turn_end, info}) do
    usage = Usage.from(Map.get(info, :usage)) || %Usage{}

    bump(totals,
      prompt_tokens: usage.prompt,
      cached_tokens: usage.cached,
      uncached_tokens: usage.uncached,
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
