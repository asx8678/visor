defmodule VisorWeb.InspectorComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias VisorWeb.InspectorComponents

  defp cache_bar(hit, miss) do
    assigns = %{hit: hit, miss: miss}

    ~H"<InspectorComponents.cache_bar hit={@hit} miss={@miss} />"
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  test "shows the prompt cache's share once a call reported one" do
    assert cache_bar(6400, 2232) == "Prompt cache 74%"
    assert cache_bar(0, 1100) == "Prompt cache 0%"
  end

  test "shows no share, rather than 0%, before any call" do
    assert cache_bar(0, 0) == "Prompt cache –"
  end

  defp status(status, turn) do
    assigns = %{status: status, turn: turn}

    ~H"<InspectorComponents.status_readout status={@status} tools_running={0} live_turn={@turn} />"
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  test "says what a model call is doing, and only says thinking when it thinks" do
    turn = %{reasoning: "", content: "", tool_calls: []}

    assert status(:streaming, nil) == "Waiting"
    assert status(:streaming, turn) == "Waiting"
    assert status(:streaming, %{turn | reasoning: "Hmm"}) == "Thinking"
    assert status(:streaming, %{turn | content: "Done"}) == "Writing"
    assert status(:streaming, %{turn | tool_calls: [%{name: "elixir"}]}) == "Writing a tool call"
  end
end
