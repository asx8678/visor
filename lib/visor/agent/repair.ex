defmodule Visor.Agent.Repair do
  @moduledoc """
  Puts a conversation's tool calls and results back in the order the
  OpenAI-format API accepts: each assistant message's tool calls answered,
  one tool message per call, before the next message, and no tool message
  without its call.

  The agent's own steps keep that order. A crash breaks it: the agent
  saves an assistant message's tool calls before they run, and an agent
  restarted mid-batch has calls without results. The agent repairs its
  messages when it restarts, with the results that had come in, and
  again before every request, in case anything else left one unanswered.
  A conversation that needs nothing comes back unchanged.
  """

  @typedoc "What a repair changed: tool messages added and dropped."
  @type info :: %{answered: non_neg_integer(), dropped: non_neg_integer()}

  @doc """
  Repairs `messages`. A call without a result gets `results[call_id]`
  when there is one, otherwise `missing`. Returns the messages and what
  changed, or nil for a conversation that needed nothing.
  """
  @spec messages([map()], %{String.t() => String.t()}, String.t()) :: {[map()], info() | nil}
  def messages(messages, results, missing) do
    {reversed, open, info} =
      Enum.reduce(messages, {[], [], %{answered: 0, dropped: 0}}, fn message, acc ->
        step(message, acc, results, missing)
      end)

    {reversed, info} = close(open, reversed, info, results, missing)

    if info.answered == 0 and info.dropped == 0,
      do: {messages, nil},
      else: {Enum.reverse(reversed), info}
  end

  # `open` holds the ids of the last assistant message's unanswered calls,
  # in call order.
  defp step(%{"role" => "tool", "tool_call_id" => id} = message, {acc, open, info}, _, _) do
    if id in open,
      do: {[message | acc], List.delete(open, id), info},
      else: {acc, open, %{info | dropped: info.dropped + 1}}
  end

  defp step(%{"role" => "tool"}, {acc, open, info}, _results, _missing),
    do: {acc, open, %{info | dropped: info.dropped + 1}}

  defp step(message, {acc, open, info}, results, missing) do
    {acc, info} = close(open, acc, info, results, missing)

    case message do
      %{"role" => "assistant", "tool_calls" => [_ | _] = calls} ->
        {[message | acc], Enum.map(calls, & &1["id"]), info}

      _other ->
        {[message | acc], [], info}
    end
  end

  defp close(open, acc, info, results, missing) do
    answers =
      for id <- open,
          do: %{
            "role" => "tool",
            "tool_call_id" => id,
            "content" => Map.get(results, id, missing)
          }

    {Enum.reverse(answers, acc), %{info | answered: info.answered + length(answers)}}
  end
end
