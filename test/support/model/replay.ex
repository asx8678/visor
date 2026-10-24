defmodule Visor.Model.Replay do
  @moduledoc """
  A model that answers with the replies a session log recorded, in their
  order, after BeamWeaver's replay transports: a session run once against
  the real model becomes a test of the harness. The scripts run for real;
  the replies don't depend on what they return. Every request is checked
  as the demo model checks it (`Visor.Model.Demo.invalid/1`), so a change
  that sends the provider a conversation out of order fails the replay.

  `load/1` takes a log's path, or its `turn_end` lines as maps with the
  log's keys (`content`, `reasoning`, `tool_calls`, `finish_reason`,
  `usage`, `model`).
  """
  @behaviour Visor.Model

  @impl true
  def info,
    do: %{
      provider: "Replay",
      model: "replay",
      endpoint: nil,
      max_tokens: nil,
      context_window: nil,
      key: :none
    }

  @doc "Loads the replies to play: a session log's path, or its turn_end lines."
  def load(path) when is_binary(path) do
    replies = for %{"event" => "turn_end"} = line <- Visor.SessionLog.Reader.read(path), do: line
    load(replies)
  end

  def load(replies) when is_list(replies) do
    if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
    {:ok, _pid} = Agent.start(fn -> replies end, name: __MODULE__)
    :ok
  end

  @doc "The replies not played yet."
  def left, do: Agent.get(__MODULE__, &length/1)

  @impl true
  def stream(request, _emit) do
    case Visor.Model.Demo.invalid(request.messages) do
      nil -> next()
      problem -> {:error, "DeepSeek returned HTTP 400. " <> problem}
    end
  end

  defp next do
    case Agent.get_and_update(__MODULE__, fn replies -> Enum.split(replies, 1) end) do
      [reply] -> {:ok, result(reply)}
      [] -> {:error, "The replay has no more replies than the log recorded."}
    end
  end

  # A logged reply as DeepSeek's client returns one (Visor.Model.DeepSeek).
  defp result(reply) do
    calls =
      for call <- reply["tool_calls"] || [],
          do: %{id: call["id"], name: call["name"], arguments: call["arguments"]}

    message = %{
      "role" => "assistant",
      "content" => reply["content"] || "",
      "reasoning_content" => reply["reasoning"] || ""
    }

    message =
      if calls == [],
        do: message,
        else: Map.put(message, "tool_calls", Enum.map(calls, &wire_call/1))

    %{
      message: message,
      tool_calls: calls,
      finish_reason: reply["finish_reason"],
      usage: reply["usage"],
      model: reply["model"] || "replay",
      chunks: 1,
      ttft_ms: 0,
      ms: 0
    }
  end

  defp wire_call(call),
    do: %{
      "id" => call.id,
      "type" => "function",
      "function" => %{"name" => call.name, "arguments" => call.arguments}
    }
end
