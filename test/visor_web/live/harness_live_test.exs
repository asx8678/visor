defmodule VisorWeb.HarnessLiveTest do
  use VisorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Visor.{Agent, Observer}

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
    assert has_element?(view, "#prompt-timeline")
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

    # The work folds into one line, and the answer stands below it.
    work = "#entries [id^='entries-work-']"
    assert has_element?(view, work, ~r/Worked [\d.]+ m?s/)
    assert has_element?(view, work, "2 model calls · 1 V call")
    assert has_element?(view, "#{work} [id^='tool-'] summary", ~s|V.read("mix.exs")|)
    assert has_element?(view, "#entries-answer-2", "Here is what came back")
    assert has_element?(view, "#last-request pre")
    assert has_element?(view, "#turn-readings", "Model call 2")
    assert has_element?(view, "#turn-history li", "#2")
    assert has_element?(view, "#turn-history li", "#1")

    # The timeline keeps the finished prompt: two model calls and a tool call.
    assert has_element?(view, "#prompt-timeline", "Last prompt")
    assert has_element?(view, "#timeline-model [data-state=done]")
    assert has_element?(view, "#timeline-tools [data-state=done]")
  end

  test "marks this tab's session once another tab has one", %{conn: conn, view: view, id: id} do
    Observer.subscribe()
    await_snapshot(fn tree -> Enum.any?(tree, &(&1.label == "session #{id}")) end)
    refute has_element?(view, "#supervision-tree", "this tab")

    {:ok, _other, _html} = live(conn, ~p"/")

    await_snapshot(fn tree ->
      Enum.count(tree, &String.starts_with?(&1.label, "session ")) > 1
    end)

    assert has_element?(view, "#supervision-tree li", ~r/session #{id}\s+this tab/)
  end

  test "keeps exited processes in the tree a while, and scripts' own out of the log",
       %{view: view} do
    Observer.subscribe()
    view |> form("#prompt-form", prompt: %{text: "read mix.exs"}) |> render_submit()
    assert_receive {:agent, {:status, :idle}}, @flow_timeout

    await_snapshot(fn tree -> Enum.any?(tree, &(&1[:ghost] && &1.label == "tool elixir")) end)
    assert has_element?(view, "#supervision-tree li.tree-gone", "exited after")
    assert has_element?(view, "#lifecycle li", "tool elixir")
    refute has_element?(view, "#lifecycle li", "sandbox")

    # The phone tab counts the processes running, not the exited rows.
    html = view |> render() |> LazyHTML.from_fragment()
    rows = html |> LazyHTML.query("#supervision-tree > li") |> Enum.count()
    gone = html |> LazyHTML.query("#supervision-tree > li.tree-gone") |> Enum.count()
    count = html |> LazyHTML.query("#tab-processes span.text-xs") |> LazyHTML.text()
    assert String.to_integer(count) == rows - gone
  end

  @tag :tmp_dir
  test "shows the session log's path once the file is written", %{conn: conn, tmp_dir: dir} do
    Application.put_env(:visor, :session_log_dir, dir)
    on_exit(fn -> Application.put_env(:visor, :session_log_dir, false) end)

    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#session-log")

    view |> element("#thinking-mode-off") |> render_click()
    assert has_element?(view, "#session-log", "#{Path.basename(dir)}/")

    [_, id] = Regex.run(~r/session (\w+)/, view |> element("#session-id") |> render())
    [{log, _path}] = Registry.lookup(Visor.Harness.Registry, {id, :log})
    _ = :sys.get_state(log)
    assert [_file] = Path.wildcard(Path.join(dir, "*.jsonl"))
  end

  test "keeps the session's model calls through /clear", %{view: view} do
    view |> form("#prompt-form", prompt: %{text: "read mix.exs"}) |> render_submit()
    assert_receive {:agent, {:status, :idle}}, @flow_timeout

    view |> form("#prompt-form", prompt: %{text: "/clear"}) |> render_submit()
    assert has_element?(view, "#console-empty")
    assert has_element?(view, "#turn-history li", "#2")
    assert has_element?(view, "#session-readings h3", "2 model calls")
  end

  test "compacts the conversation with /compact, or says there is nothing to", %{view: view} do
    view |> form("#prompt-form", prompt: %{text: "/compact"}) |> render_submit()
    assert has_element?(view, "#entries", "There is nothing to compact yet.")

    view |> form("#prompt-form", prompt: %{text: "read mix.exs"}) |> render_submit()
    assert_receive {:agent, {:status, :idle}}, @flow_timeout

    view |> form("#prompt-form", prompt: %{text: "/compact"}) |> render_submit()
    assert_receive {:agent, {:compaction, %{reason: :manual}}}
    assert has_element?(view, "#entries", "Compacted the conversation because you asked")
  end

  test "shows the calls an elixir script makes under its tool card", %{view: view} do
    view
    |> form("#prompt-form", prompt: %{text: "Count functions in each file"})
    |> render_submit()

    assert_receive {:agent, {:tool_end, %{name: "elixir", status: :ok}}}, @flow_timeout
    assert_receive {:agent, {:status, :idle}}, @flow_timeout

    card = "#entries [id^='entries-work-'] [id^='tool-']"

    assert has_element?(
             view,
             "#{card} summary",
             ~r/V.glob\("lib\/\*\*\/\*.ex"\) · V.grep\(.* \+\d+ more/
           )

    assert has_element?(view, "#{card} ol li", ~s|V.glob("lib/**/*.ex")|)
    assert has_element?(view, "#{card} ol li", ~s|V.grep(|)
  end

  defp await_snapshot(found?) do
    receive do
      {:observer, :snapshot, %{tree: tree}} -> found?.(tree) || await_snapshot(found?)
    after
      2_000 -> flunk("no runtime snapshot showed it")
    end
  end

  test "shows background jobs, and the prompt a job's end starts", %{view: view} do
    assert has_element?(view, "#jobs #jobs-empty")

    prompt = ~S|> V.sh("sleep 0.3", background: true)|
    view |> form("#prompt-form", prompt: %{text: prompt}) |> render_submit()
    assert_receive {:agent, {:job_start, %{id: "j1"}}}, @flow_timeout
    assert has_element?(view, "#job-j1", "running")
    assert has_element?(view, "#stop-job-j1")

    assert_receive {:agent, {:job_end, %{id: "j1"}}}, @flow_timeout
    assert has_element?(view, "#job-j1", "exit 0")
    refute has_element?(view, "#stop-job-j1")

    # The wake is a prompt of its own, with its work line and answer.
    assert_receive {:agent, {:wake, _text}}, @flow_timeout
    assert_receive {:agent, {:prompt_end, _}}, @flow_timeout
    assert has_element?(view, "#entries", "Visor, for the background jobs that ended")
    assert has_element?(view, "#entries", "[Visor: background job j1 (sleep 0.3)")
    assert view |> element("#entries") |> render() |> String.contains?("Worked")
  end

  test "lists and stops background jobs with /jobs", %{view: view} do
    view |> form("#prompt-form", prompt: %{text: "/jobs"}) |> render_submit()
    assert has_element?(view, "#entries", "No background jobs yet.")

    view |> form("#prompt-form", prompt: %{text: "/jobs wake off"}) |> render_submit()
    assert_receive {:agent, {:settings, %{jobs_wake: false}}}

    prompt = ~S|> V.sh("touch /dev/null; sleep 30", background: true)|
    view |> form("#prompt-form", prompt: %{text: prompt}) |> render_submit()
    assert_receive {:agent, {:job_start, %{id: "j1"}}}, @flow_timeout
    assert_receive {:agent, {:prompt_end, _}}, @flow_timeout

    view |> form("#prompt-form", prompt: %{text: "/jobs"}) |> render_submit()
    assert has_element?(view, "#entries", ~r/j1\s+running/)

    view |> element("#stop-job-j1") |> render_click()
    assert_receive {:agent, {:job_end, %{id: "j1", status: :killed}}}, @flow_timeout
    assert has_element?(view, "#job-j1", "stopped")
    assert has_element?(view, "#entries", "Stopped job j1.")
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
