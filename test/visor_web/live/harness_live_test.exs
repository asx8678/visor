defmodule VisorWeb.HarnessLiveTest do
  use VisorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Visor.Agent

  # A prompt runs real tools, and the first elixir script also warms up
  # Dune, which can take longer than assert_receive's default 100 ms.
  @flow_timeout 2_000

  setup %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    id =
      view
      |> element("#session-id")
      |> render()
      |> then(&Regex.run(~r/session (\w+)/, &1))
      |> List.last()

    Agent.subscribe(id)
    %{view: view, id: id}
  end

  test "shows the process view, console and model inspector", %{view: view} do
    assert has_element?(view, "#runtime-header")
    assert has_element?(view, "#supervision-tree")
    assert has_element?(view, "#lamp-field")
    assert has_element?(view, "#prompt-form")
    assert has_element?(view, "#model-inspector #agent-status")
    assert has_element?(view, "#model-inspector #context-meter")
    assert has_element?(view, "textarea#prompt-input")
    assert has_element?(view, "#console-empty")
    assert has_element?(view, "#panel-tabs #tab-console[aria-pressed=true]")
    assert has_element?(view, "#panel-tabs #tab-processes")
  end

  test "runs a prompt through the agent and shows its turns and tools", %{view: view} do
    view |> form("#prompt-form", prompt: %{text: "read mix.exs"}) |> render_submit()

    assert_receive {:agent, {:tool_end, %{name: "elixir"}}}, @flow_timeout
    assert_receive {:agent, {:status, :idle}}, @flow_timeout

    assert has_element?(view, "#entries-turn-1")
    assert has_element?(view, "#entries-turn-2")
    assert has_element?(view, "#entries [id^='entries-tool-']", "elixir")
    assert has_element?(view, "#last-request pre")
  end

  test "shows the calls an elixir script makes under its tool card", %{view: view} do
    view
    |> form("#prompt-form", prompt: %{text: "Count functions in each file"})
    |> render_submit()

    assert_receive {:agent, {:tool_end, %{name: "elixir", status: :ok}}}, @flow_timeout
    assert_receive {:agent, {:status, :idle}}, @flow_timeout

    card = "#entries [id^='entries-tool-']"
    assert has_element?(view, card, ~r/\d+ calls in one process/)
    assert has_element?(view, "#{card} ol li", ~s|V.glob("lib/**/*.ex")|)
    assert has_element?(view, "#{card} ol li", ~s|V.grep(|)
  end

  test "handles slash commands", %{view: view} do
    view |> form("#prompt-form", prompt: %{text: "/help"}) |> render_submit()
    assert has_element?(view, "#entries", "/effort low|high|max")

    view |> form("#prompt-form", prompt: %{text: "/effort max"}) |> render_submit()
    assert_receive {:agent, {:settings, %{effort: "max"}}}
    assert has_element?(view, "#reasoning-effort-max[aria-pressed=true]")

    view |> form("#prompt-form", prompt: %{text: "/nope"}) |> render_submit()
    assert has_element?(view, "#entries", "There is no /nope command")
  end

  test "takes the layout the page detects", %{view: view} do
    assert has_element?(view, "#visor-shell[data-layout=desktop]")
    render_hook(view, "client_layout", %{"layout" => "phone"})
    assert has_element?(view, "#visor-shell[data-layout=phone]")
    render_hook(view, "client_layout", %{"layout" => "huge"})
    assert has_element?(view, "#visor-shell[data-layout=phone]")
  end

  test "starts phones in the phone layout", %{conn: conn} do
    iphone =
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"

    {:ok, view, _html} = conn |> put_req_header("user-agent", iphone) |> live(~p"/")
    assert has_element?(view, "#visor-shell[data-layout=phone]")
  end

  test "changes thinking mode from the inspector", %{view: view} do
    view |> element("#thinking-mode-off") |> render_click()
    assert_receive {:agent, {:settings, %{thinking: false}}}
    assert has_element?(view, "#thinking-mode-off[aria-pressed=true]")
  end
end
