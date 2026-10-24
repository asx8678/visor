defmodule Visor.Compaction do
  @moduledoc """
  Deterministic compaction, after pi-fabric's: no model call, and the
  same conversation always compacts to the same bytes.

  When the context passes its threshold, the messages before a cut become
  one summary (`Visor.Compaction.Summary`) and the rest stay as they were.
  The cut is the earliest that keeps the recent conversation within its
  budget, at a user or assistant message, never between a tool call and
  its results. The summary is rebuilt from the original messages every
  time, never from an earlier summary, and a compaction that wouldn't
  bring the context under its target isn't made.

  Sizes are counted the way pi counts them: a message's tokens are
  estimated from its size, then scaled by how the provider counted the
  last request (`scale`).
  """

  alias Visor.Compaction.Summary
  alias Visor.Limits

  # After a compaction the context may fill at most this much of the window.
  @occupancy 0.65
  # Of the window less the room kept for the response, a hard ceiling.
  @safety 0.9
  # A compaction must make the context smaller than this share of before.
  @reduction 0.95

  @doc "A term's size in estimated tokens: four bytes to a token."
  def estimate(term), do: div(:erlang.external_size(term), 4) + 1

  @doc """
  The messages the model sees: the summary of what was compacted, then the
  conversation from the cut on. The summary goes into the first kept user
  message, so two user messages never follow each other.
  """
  def surface(messages, nil), do: messages

  def surface(messages, %{from: from, summary: summary}) do
    case Enum.drop(messages, from) do
      [%{"role" => "user", "content" => text} = first | rest] ->
        [%{first | "content" => summary <> "\n\n" <> text} | rest]

      kept ->
        [%{"role" => "user", "content" => summary} | kept]
    end
  end

  @doc """
  Compacts `messages` when the context has passed `:threshold`, or now
  with `force: true` (`/compact`, or a request the provider rejected as too
  long). Returns `{:ok, compaction, info}` with the compaction to keep, or
  `:keep` when there is nothing to compact or no summary would fit.

  Options:

    * `:compaction` - the current compaction, or nil
    * `:facts` - what each tool call's V calls did, by tool call id
    * `:fixed` - estimated tokens every request sends besides the
      messages (the system prompt and the tools)
    * `:scale` - provider tokens per estimated token
    * `:threshold` - the context size, in provider tokens, that compacts
    * `:window` - the context window in provider tokens, or nil
    * `:force` - compact even under the threshold
    * `:carry` - what every summary keeps (`V.carry/1`)
  """
  def compact(messages, opts) do
    current = Keyword.get(opts, :compaction)
    scale = Keyword.fetch!(opts, :scale)
    fixed = Keyword.fetch!(opts, :fixed)
    tokens = round(scale * (fixed + total(surface(messages, current))))

    if Keyword.get(opts, :force, false) or tokens >= Keyword.fetch!(opts, :threshold),
      do: plan(messages, current, tokens, opts),
      else: :keep
  end

  defp plan(messages, current, tokens, opts) do
    scale = Keyword.fetch!(opts, :scale)
    fixed = Keyword.fetch!(opts, :fixed)
    reserve = div(Limits.summary_bytes(), 4)
    target = target(tokens, fixed, scale, reserve, Keyword.get(opts, :window))
    budget = max(floor(target / scale) - fixed - reserve, 0)

    with {:ok, from} <- cut(messages, current, budget) do
      # Never more than half of what it replaces: the last summary and the
      # messages it newly covers (dsh-fabric's guard).
      start = if current, do: current.from, else: 0
      replaced = total(Enum.slice(messages, start, from - start))
      replaced = if current, do: replaced + estimate(current.summary), else: replaced
      limit = min(Limits.summary_bytes(), max(replaced * 2 - 256, 256))
      summarized = Enum.take(messages, from)
      facts = Keyword.get(opts, :facts, %{})
      summary = Summary.compile(summarized, facts, limit, Keyword.get(opts, :carry, []))
      after_tokens = round(scale * (fixed + estimate(summary) + total(Enum.drop(messages, from))))

      if byte_size(summary) <= Limits.summary_bytes() and after_tokens <= target do
        info = %{
          summarized: from,
          kept: length(messages) - from,
          tokens_before: tokens,
          tokens_after: after_tokens,
          summary_bytes: byte_size(summary)
        }

        {:ok, %{from: from, summary: summary}, info}
      else
        :keep
      end
    end
  end

  # The context after a compaction aims under every ceiling at once: the
  # recent conversation and a full summary, a share of the window, the
  # window less its reserve, and less than before.
  defp target(tokens, fixed, scale, reserve, window) do
    continuity = scale * (fixed + Limits.keep_recent_tokens() + reserve)

    ceilings =
      if is_integer(window),
        do: [@occupancy * window, @safety * (window - Limits.reserve_tokens())],
        else: []

    Enum.min([continuity, @reduction * tokens | ceilings])
  end

  @doc """
  Where to cut: the earliest message, after the last compaction's cut,
  whose tail fits `budget` estimated tokens, starts at a user or assistant
  message and leaves no tool call apart from its results. Everything when
  no tail fits. `:keep` when there is nothing new to compact.
  """
  def cut(messages, current, budget) do
    count = length(messages)
    first = if current, do: current.from + 1, else: 1
    spans = call_spans(messages)

    tails =
      messages |> Enum.map(&estimate/1) |> Enum.reverse() |> Enum.scan(&+/2) |> Enum.reverse()

    found =
      messages
      |> Enum.zip(tails)
      |> Enum.with_index()
      |> Enum.find_value(fn {{message, tail}, index} ->
        if index >= first and message["role"] != "tool" and tail <= budget and
             closed?(spans, index),
           do: index
      end)

    cond do
      count < first -> :keep
      found -> {:ok, found}
      true -> {:ok, count}
    end
  end

  # For each tool result, the index of the assistant message that called it
  # and its own index.
  defp call_spans(messages) do
    calls =
      for {%{"role" => "assistant", "tool_calls" => calls}, index} <- Enum.with_index(messages),
          %{"id" => id} <- calls,
          into: %{},
          do: {id, index}

    for {%{"role" => "tool", "tool_call_id" => id}, index} <- Enum.with_index(messages),
        call = calls[id],
        do: {call, index}
  end

  # A cut before `index` keeps every call with its results.
  defp closed?(spans, index),
    do: not Enum.any?(spans, fn {call, result} -> call < index and result >= index end)

  defp total(messages), do: messages |> Enum.map(&estimate/1) |> Enum.sum()
end
