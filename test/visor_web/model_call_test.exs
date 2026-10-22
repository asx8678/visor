defmodule VisorWeb.ModelCallTest do
  use ExUnit.Case, async: true

  alias VisorWeb.ModelCall

  defp turn(fields), do: Map.merge(%{reasoning: "", content: "", tool_calls: []}, fields)

  test "reads a streaming call's phase from what has come in" do
    assert ModelCall.phase(turn(%{})) == :waiting
    assert ModelCall.phase(turn(%{reasoning: "Let me look"})) == :thinking
    assert ModelCall.phase(turn(%{reasoning: "Let me look", content: "Here"})) == :reply

    # A tool call's arguments stream in with no content or reasoning.
    assert ModelCall.phase(turn(%{tool_calls: [%{name: "elixir"}]})) == :tool_call
  end

  test "counts a call the user stopped as stopped, not failed" do
    refute ModelCall.failed?("stop")
    refute ModelCall.failed?("tool_calls")
    refute ModelCall.failed?("interrupted")
    assert ModelCall.failed?("length")
    assert ModelCall.failed?("error")
    assert ModelCall.failed?("crashed")
    assert ModelCall.failed?(nil)

    assert ModelCall.finish_text("interrupted") == "stopped"
    assert ModelCall.finish_text("error") == "failed"
  end
end
