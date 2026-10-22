defmodule VisorWeb.ModelCall do
  @moduledoc """
  How a model call reads wherever the harness view shows one (the work
  line, the process tree, the timeline and the inspector): what a
  streaming call is doing, and how a finished one ended. The panels read
  it from here, so they never disagree.
  """

  @doc """
  What a streaming call is doing, from what has come in so far:
  `:waiting` for its first token, `:thinking`, writing the `:reply`, or
  writing a `:tool_call`.
  """
  def phase(%{tool_calls: [_ | _]}), do: :tool_call
  def phase(%{content: content}) when content not in [nil, ""], do: :reply
  def phase(%{reasoning: reasoning}) when reasoning not in [nil, ""], do: :thinking
  def phase(_turn), do: :waiting

  def phase_text(:waiting), do: "waiting for the first token"
  def phase_text(:thinking), do: "thinking"
  def phase_text(:reply), do: "writing the reply"
  def phase_text(:tool_call), do: "writing a tool call"

  @doc "How a call ended, from its finish reason."
  def finish_text("stop"), do: "answered"
  def finish_text("tool_calls"), do: "called tools"
  def finish_text("length"), do: "cut off at max tokens"
  def finish_text("interrupted"), do: "stopped"
  def finish_text("crashed"), do: "crashed"
  def finish_text("error"), do: "failed"
  def finish_text(nil), do: "ended without a reason"
  def finish_text(other), do: other

  @doc "Whether a call ended badly. A call the user stopped didn't fail."
  def failed?(reason), do: reason not in ["stop", "tool_calls", "interrupted"]
end
