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
    assert has_element?(view, "#entries", "Visor, for what came in while the agent was idle")
    assert has_element?(view, "#entries", "[Visor: background job j1 (sleep 0.3)")
    assert view |> element("#entries") |> render() |> String.contains?("Worked")
  end

  test "shows a script's progress notes under its step, not in its result", %{view: view} do
    prompt = ~S|> V.note("halfway there"); V.exists?("mix.exs")|
    view |> form("#prompt-form", prompt: %{text: prompt}) |> render_submit()
    assert_receive {:agent, {:script_note, _call_id, "halfway there"}}, @flow_timeout
    assert_receive {:agent, {:tool_end, %{result: result}}}, @flow_timeout
    assert_receive {:agent, {:prompt_end, _}}, @flow_timeout

    refute result =~ "halfway"
    assert has_element?(view, "#entries [id^='tool-'] li", "halfway there")
  end

  @tag :tmp_dir
  test "lists saved scripts and runs one with /run", %{view: view, tmp_dir: tmp_dir} do
    previous = Application.get_env(:visor, :workspace)
    Application.put_env(:visor, :workspace, tmp_dir)
    on_exit(fn -> Application.put_env(:visor, :workspace, previous) end)

    view |> form("#prompt-form", prompt: %{text: "/scripts"}) |> render_submit()
    assert has_element?(view, "#entries", "No saved scripts yet.")

    {:ok, _script} = Visor.Scripts.save("answer", "6 * 7", "the answer")
    view |> form("#prompt-form", prompt: %{text: "/scripts"}) |> render_submit()
    assert has_element?(view, "#entries", ~r/answer\s+the answer/)

    view |> form("#prompt-form", prompt: %{text: "/run answer"}) |> render_submit()
    assert has_element?(view, "#entries", "Running saved script answer")
    assert_receive {:agent, {:script_run, %{name: "answer", status: :ok}}}, @flow_timeout
    assert has_element?(view, "#entries", "=> 42")
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

  describe "a page that closes or reloads" do
    setup do
      Application.put_env(:visor, :session_grace_ms, 1_000)
      on_exit(fn -> Application.put_env(:visor, :session_grace_ms, 0) end)
    end

    # Pages closed with no grace left, so their sessions end with them and
    # the next test's tree doesn't hold them.
    defp close(views) do
      Application.put_env(:visor, :session_grace_ms, 0)
      for view <- views, do: GenServer.stop(view.pid, :normal)
    end

    test "comes back to its session and conversation within the grace period", %{
      conn: conn,
      view: view,
      id: id
    } do
      view |> form("#prompt-form", prompt: %{text: "read mix.exs"}) |> render_submit()
      assert_receive {:agent, {:prompt_end, _}}, @flow_timeout

      GenServer.stop(view.pid, :normal)
      {:ok, back, _html} = live(conn, ~p"/?session=#{id}")
      assert_receive {:agent, {:reattached, %{messages: 4}}}, @flow_timeout

      assert has_element?(back, "#session-id", "session #{id}")
      assert has_element?(back, "#entries", "read mix.exs")
      assert has_element?(back, "#entries", "Here is what came back")
      assert has_element?(back, "#entries", "Back in session #{id}, with its 4 messages.")

      # Another page doesn't take a session a page owns: it gets its own.
      {:ok, other, _html} = live(conn, ~p"/?session=#{id}")
      refute has_element?(other, "#session-id", "session #{id}")
      close([back, other])
    end

    test "shows the rest of a prompt that was running when it reloaded", %{
      conn: conn,
      view: view,
      id: id
    } do
      view |> form("#prompt-form", prompt: %{text: "$ sleep 1"}) |> render_submit()
      assert_receive {:agent, {:tool_start, %{pid: pid}}} when is_pid(pid), @flow_timeout

      GenServer.stop(view.pid, :normal)
      {:ok, back, _html} = live(conn, ~p"/?session=#{id}")
      assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000
      assert has_element?(back, "#entries", "Here is what came back")
      close([back])
    end

    test "ends the session once the grace period is over", %{view: view, id: id} do
      [{session, _store}] = Registry.lookup(Visor.Harness.Registry, {id, :store})
      ref = Process.monitor(session)
      GenServer.stop(view.pid, :normal)
      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 500
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 2_000
    end
  end

  test "handles slash commands", %{view: view} do
    view |> form("#prompt-form", prompt: %{text: "/help"}) |> render_submit()
    assert has_element?(view, "#entries", "/effort low|high|max")

    view |> form("#prompt-form", prompt: %{text: "/effort max"}) |> render_submit()
    assert_receive {:agent, {:settings, %{effort: "max"}}}
    assert has_element?(view, "#reasoning-effort-max[aria-pressed=true]")

    view |> form("#prompt-form", prompt: %{text: "/nope"}) |> render_submit()
    assert has_element?(view, "#entries", "There is no /nope command")

    view |> form("#prompt-form", prompt: %{text: "/resume"}) |> render_submit()
    assert has_element?(view, "#entries", "/resume needs a session's id.")
  end

  test "tells the page a prompt ended, for a notification when its tab is hidden",
       %{view: view} do
    assert has_element?(view, "#prompt-notify[phx-hook]")
    view |> form("#prompt-form", prompt: %{text: "list the files"}) |> render_submit()
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, @flow_timeout
    assert_push_event(view, "prompt_done", %{reason: :answered, steps: 2})
  end

  test "shows and sets the spending limits", %{view: view, id: id} do
    submit = fn text -> view |> form("#prompt-form", prompt: %{text: text}) |> render_submit() end

    submit.("/budget")
    assert has_element?(view, "#entries", "This prompt has spent $0.0000 of $1.00")

    submit.("/budget prompt 2.5")
    assert %{limits: %{prompt: 2.5}} = Agent.settings(id)
    assert has_element?(view, "#entries", "The prompt's limit is now $2.50.")

    submit.("/budget session lots")
    assert has_element?(view, "#entries", "/budget session takes a number of dollars")
  end

  test "turns the reviewer and prewalk on and off", %{view: view, id: id} do
    submit = fn text -> view |> form("#prompt-form", prompt: %{text: text}) |> render_submit() end

    submit.("/advisor correctness")
    assert Visor.Reviewer.status(id) == %{mode: :advisor, text: "correctness"}
    assert has_element?(view, "#entries", "The advisor is on")

    submit.("/supervise")
    assert has_element?(view, "#entries", "/supervise needs a goal")
    submit.("/supervise all tests pass")
    assert Visor.Reviewer.status(id) == %{mode: :supervisor, text: "all tests pass"}
    submit.("/supervise off")
    assert Visor.Reviewer.status(id) == nil
    assert has_element?(view, "#entries", "The reviewer is off.")

    submit.("/prewalk on")
    assert_receive {:agent, {:settings, %{prewalk: true}}}
    assert has_element?(view, "#entries", "Prewalk is on")
    submit.("/prewalk maybe")
    assert has_element?(view, "#entries", "/prewalk takes on or off.")
    submit.("/prewalk off")
    assert_receive {:agent, {:settings, %{prewalk: false}}}
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
