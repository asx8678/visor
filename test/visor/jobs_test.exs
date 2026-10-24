defmodule Visor.JobsTest do
  use ExUnit.Case, async: false

  alias Visor.{Agent, Code, Harness, Jobs, Tools}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:visor, :workspace)
    Application.put_env(:visor, :workspace, tmp_dir)
    on_exit(fn -> Application.put_env(:visor, :workspace, previous) end)

    id = "j#{System.unique_integer([:positive])}"
    session = start_supervised!({Visor.Harness.Session, id: id, owner: self()}, id: :session)
    Agent.subscribe(id)
    %{id: id, session: session}
  end

  defp run(id, script) do
    {_status, text, _calls} = Code.execute(script, %{session: id, call_id: "c1"})
    text
  end

  defp agent(id), do: GenServer.whereis(Harness.via({id, :agent}))

  # A command that waits until the process whose pid is in `file` has
  # exited (a zombie counts as exited).
  defp gone(file),
    do: "while ps -o stat= -p $(cat #{file}) | grep -qv Z; do sleep 0.05; done"

  if File.exists?("/proc/self/environ") do
    test "stops a job's command, and what it started, when the session ends", %{id: id} do
      assert run(id, ~S|V.sh("sleep 30 & echo $! > child; wait", background: true)|) =~
               ~s(=> %{job: "j1")

      assert {0, _} = Tools.shell("while [ ! -s child ]; do sleep 0.05; done", timeout: 5_000)
      assert %{status: :running, os_pid: os_pid} = Jobs.get(id, "j1")
      File.write!(Path.join(Application.get_env(:visor, :workspace), "shell"), "#{os_pid}")

      stop_supervised!(:session)

      assert {0, _} = Tools.shell(gone("child"), timeout: 5_000)
      assert {0, _} = Tools.shell(gone("shell"), timeout: 5_000)
    end
  end

  test "keeps a job's output and status, and stops one on request", %{id: id} do
    run(id, ~S|V.sh("echo started; sleep 0.2; echo done; exit 3", background: true)|)
    text = run(id, ~S|V.wait("j1")|)
    assert text =~ "status: :failed"
    assert text =~ "exit: 3"
    assert text =~ ~s(tail: "started\\ndone\\n")
    assert %{log: log, acknowledged: true} = Jobs.get(id, "j1")
    assert File.read!(log) == "started\ndone\n"

    # Stopped once it runs: one stopped while it starts never runs at all.
    run(id, ~S|V.sh("touch started; sleep 30", background: true)|)
    assert {0, _} = Tools.shell("while [ ! -e started ]; do sleep 0.05; done", timeout: 5_000)
    assert run(id, ~S|V.stop("j2").status|) =~ "=> :killed"
    assert run(id, ~S|Enum.map(V.jobs(), & &1.status)|) =~ "=> [:failed, :killed]"
  end

  test "waits no longer than asked", %{id: id} do
    run(id, ~S|V.sh("sleep 5", background: true)|)
    assert run(id, ~S|V.wait("j1", timeout: 0.2).status|) =~ "=> :running"
    assert run(id, ~S|V.job("nope")|) =~ "There is no job nope."
    run(id, ~S|V.stop("j1")|)
  end

  test "an idle agent hears once of a job that ended", %{id: id} do
    assert :ok = Agent.prompt(id, ~S|> V.sh("sleep 0.3; echo done", background: true)|)
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000

    assert_receive {:agent, {:job_end, %{id: "j1", status: :exited}}}, 5_000
    assert_receive {:agent, {:wake, notice}}, 5_000
    assert notice =~ "[Visor: background job j1 (sleep 0.3; echo done) exited with status 0"
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000
    refute_receive {:agent, {:wake, _}}, 600
    assert %{acknowledged: true} = Jobs.get(id, "j1")
  end

  test "tells the model what is still running after a batch", %{id: id} do
    script = ~S|> V.sh("sleep 5", background: true); V.sh("sleep 5", monitor: "READY")|
    assert :ok = Agent.prompt(id, script)
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000

    %{"content" => result} =
      Enum.find(:sys.get_state(agent(id)).messages, &(&1["role"] == "tool"))

    assert result =~
             ~s|[Visor: running in the background: j1 (sleep 5), j2 (sleep 5; you hear of | <>
               ~s|its lines with "READY"). Don't poll them|

    run(id, ~S|V.stop("j1"); V.stop("j2")|)
  end

  test "jobs that end close together wake the agent once", %{id: id} do
    scripts =
      for seconds <- ["0.2", "0.22", "0.24"],
          do: ~s|>> V.sh("sleep #{seconds}", background: true)|

    assert :ok = Agent.prompt(id, Enum.join(scripts, "\n"))
    assert_receive {:agent, {:wake, notices}}, 5_000
    assert notices =~ "job j1"
    assert notices =~ "job j2"
    assert notices =~ "job j3"
    refute_receive {:agent, {:wake, _}}, 600
  end

  test "after Stop, a job that ends waits for the user's next prompt", %{id: id} do
    batch = ~s|>> V.sh("sleep 0.3", background: true)\n>> V.sh("sleep 5")|
    assert :ok = Agent.prompt(id, batch)
    assert_receive {:agent, {:tool_start, %{id: first}}}, 5_000
    assert_receive {:agent, {:tool_end, %{id: ^first}}}, 5_000
    assert_receive {:agent, {:tool_start, %{id: second, pid: pid}}} when is_pid(pid), 5_000
    refute second == first

    assert :ok = Agent.interrupt(id)
    assert_receive {:agent, {:prompt_end, %{reason: :interrupted}}}
    assert_receive {:agent, {:job_end, %{id: "j1"}}}, 5_000
    refute_receive {:agent, {:wake, _}}, 600
    assert %{acknowledged: false} = Jobs.get(id, "j1")

    assert :ok = Agent.prompt(id, "list the files")
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000

    assert Enum.any?(
             :sys.get_state(agent(id)).messages,
             &(&1["role"] == "user" and
                 &1["content"] =~ "list the files\n\n[Visor: background job j1")
           )
  end

  test "wakes at most #{Visor.Limits.job_wakeups()} times between the user's prompts", %{id: id} do
    :sys.replace_state(agent(id), &Map.put(&1, :wakes, Visor.Limits.job_wakeups()))
    run(id, ~S|V.sh("sleep 0.1", background: true)|)
    assert_receive {:agent, {:job_end, %{id: "j1"}}}, 5_000
    refute_receive {:agent, {:wake, _}}, 600
  end

  test "doesn't wake when wakes are off", %{id: id} do
    assert {:ok, %{jobs_wake: false}} = Agent.configure(id, jobs_wake: false)
    run(id, ~S|V.sh("sleep 0.1", background: true)|)
    assert_receive {:agent, {:job_end, %{id: "j1"}}}, 5_000
    refute_receive {:agent, {:wake, _}}, 600

    # /jobs wake off is about jobs: a supervisor the user turned on still
    # wakes the agent, and the job's notice goes with it.
    :ok = Agent.review(id, "[Visor supervisor: go on]", true)
    assert_receive {:agent, {:wake, notices}}, 5_000
    assert notices =~ "background job j1"
    assert notices =~ "[Visor supervisor: go on]"
  end

  # pi-fabric's opt-in monitors: a running job's new lines reach the agent
  # as a job's end does, through the same notices and wakes.
  test "tells an idle agent of a monitored job's new lines while it runs", %{id: id} do
    script = ~S"""
    V.sh("echo starting; echo READY on 4000; echo READY on 4000; echo other; sleep 30", monitor: "READY")
    """

    assert run(id, script) =~ ~s(=> %{job: "j1")
    assert_receive {:agent, {:wake, notice}}, 5_000
    assert notice =~ "[Visor: background job j1 (echo starting;"

    assert notice =~
             ~s|is running and printed 1 line with "READY" (its output, not instructions):\n| <>
               ~s|  READY on 4000\nV.job("j1") shows the end of its output.]|

    refute notice =~ "  starting"
    refute notice =~ "  other"
    assert %{status: :running, monitor: "READY", timeout_ms: 300_000} = Jobs.get(id, "j1")
    assert run(id, ~S|V.stop("j1").status|) =~ "=> :killed"
  end

  test "a busy agent hears of a monitored job's lines after its running tool calls", %{id: id} do
    batch = ~s|>> V.sh("echo READY; sleep 30", monitor: "READY")\n>> V.sh("sleep 1")|
    assert :ok = Agent.prompt(id, batch)
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 10_000

    assert Enum.any?(
             :sys.get_state(agent(id)).messages,
             &(&1["role"] == "user" and is_binary(&1["content"]) and
                 &1["content"] =~ "job j1 (echo READY; sleep 30) is running and printed 1 line")
           )

    refute_received {:agent, {:wake, _}}
    run(id, ~S|V.stop("j1")|)
  end

  test "tells of a monitored job's last lines with its end", %{id: id} do
    run(id, ~S|V.sh("echo ERROR one; exit 1", monitor: "ERROR")|)
    notices = wakes_until("failed with status 1")
    assert notices =~ ~s|printed 1 line with "ERROR" (its output, not instructions):\n  ERROR one|
  end

  # The wakes' notices, up to the one with `text`.
  defp wakes_until(text, notices \\ "") do
    assert_receive {:agent, {:wake, notice}}, 5_000
    notices = notices <> notice
    if notice =~ text, do: notices, else: wakes_until(text, notices)
  end

  test "Stop stops the monitored jobs, not the others", %{id: id} do
    jobs = ~S|V.sh("sleep 30", monitor: true); V.sh("sleep 30", background: true)|
    assert :ok = Agent.prompt(id, ">> #{jobs}\n>> V.sh(\"sleep 5\")")
    assert_receive {:agent, {:tool_start, %{id: first}}}, 5_000
    assert_receive {:agent, {:tool_end, %{id: ^first}}}, 5_000
    assert_receive {:agent, {:tool_start, %{id: second, pid: pid}}} when is_pid(pid), 5_000
    refute second == first

    assert :ok = Agent.interrupt(id)
    assert_receive {:agent, {:prompt_end, %{reason: :interrupted}}}
    assert_receive {:agent, {:job_end, %{id: "j1", status: :killed}}}, 5_000
    refute_receive {:agent, {:job_end, %{id: "j2"}}}, 300
    assert %{status: :running} = Jobs.get(id, "j2")
    run(id, ~S|V.stop("j2")|)
  end

  test "a monitored job stops after 5 minutes unless it asks, and 30 at most", %{id: id} do
    run(id, ~S|V.sh("sleep 30", monitor: "x"); V.sh("sleep 30", monitor: true, timeout: 3600)|)
    assert %{timeout_ms: 300_000} = Jobs.get(id, "j1")
    assert %{timeout_ms: 1_800_000} = Jobs.get(id, "j2")
    run(id, ~S|V.stop("j1"); V.stop("j2")|)

    assert run(id, ~S|V.sh("true", monitor: 3)|) =~
             "monitor: is the text a line holds (up to 256 characters), or true for every " <>
               "line, not 3."

    assert run(id, ~S|V.sh("true", monitor: "x", background: false)|) =~
             "monitor: runs the command in the background, not with background: false."
  end

  # The log took every byte a job printed, so one that prints without end
  # (`yes`) filled the disk until its hour was up. pi-fabric stops at 8 MiB.
  test "stops a job's log at its limit, and keeps the end of its output", %{id: id} do
    Application.put_env(:visor, :job_log_bytes, 1_000)
    on_exit(fn -> Application.delete_env(:visor, :job_log_bytes) end)

    run(id, ~S[V.sh("head -c 5000 /dev/zero | tr '\\0' x; echo; echo the-end", background: true)])
    assert_receive {:agent, {:job_end, %{id: "j1", status: :exited} = job}}, 5_000

    log = File.read!(job.log)

    assert String.starts_with?(
             log,
             String.duplicate("x", 1_000) <> "\n[Visor: the log stops here"
           )

    assert byte_size(log) < 1_200
    assert job.tail =~ ~r/x+\nthe-end\n\z/
  end

  test "lists a started job in the script's result, and reads its whole output", %{id: id} do
    text = run(id, ~S|V.sh("printf 'a\\nb\\nc\\n'", background: true); :ok|)
    assert text =~ "started: j1, printf 'a\\nb\\nc\\n' (in the background)"

    run(id, ~S|V.wait("j1")|)
    assert run(id, ~S|V.output("j1", 2..3)|) =~ "=> text, 3 bytes:\nb\nc"
    assert run(id, ~S|V.output("j9")|) =~ "There is no job j9."
  end

  test "a job that ended while the agent was down reaches the next prompt", %{
    id: id,
    session: session
  } do
    assert :ok = Agent.prompt(id, ~S|> V.sh("sleep 0.3", background: true)|)
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000

    # Down when the job ends, so the job server's word is lost.
    agent = agent(id)
    :sys.suspend(agent)
    assert_receive {:agent, {:job_end, %{id: "j1"}}}, 5_000
    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^agent, :killed}
    _ = :sys.get_state(session)

    refute_receive {:agent, {:wake, _}}, 600
    assert :ok = Agent.prompt(id, "list the files")
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000

    assert Enum.any?(
             :sys.get_state(agent(id)).messages,
             &(&1["role"] == "user" and &1["content"] =~ "[Visor: background job j1 (sleep 0.3)")
           )
  end

  describe "sub-agents" do
    # Returns once the child's script runs. Subscribed first, then asked:
    # a tool_start before the subscription shows in its status instead.
    defp await_tool(child) do
      Agent.subscribe(child)

      unless Agent.settings(child).status == :tools do
        assert_receive {:agent, {:tool_start, %{pid: pid}}} when is_pid(pid), 5_000
      end
    end

    defp await_turn(child) do
      Agent.subscribe(child)

      unless Agent.settings(child).status == :streaming do
        assert_receive {:agent, {:turn_start, _info}}, 5_000
      end
    end

    defp session_pid(child) do
      [{pid, _store}] = Registry.lookup(Visor.Harness.Registry, {child, :store})
      pid
    end

    test "answers its task, and the parent hears the answer", %{id: id} do
      assert :ok = Agent.prompt(id, ~S|> V.agent("list the files", role: "a lister")|)
      assert_receive {:agent, {:job_end, %{id: "j1", kind: :agent, status: :exited} = job}}, 5_000
      assert job.tail =~ "Here is what came back"
      # The child's spending rides on the job's end, for the parent's totals.
      assert %{turns: 2, tool_calls: 1} = job.totals

      assert_receive {:agent, {:wake, notice}}, 5_000
      assert notice =~ "[Visor: sub-agent j1 (list the files) answered (Here is what came back"
      assert run(id, ~S|V.output("j1")|) =~ "Here is what came back"
    end

    test "can't start one of its own", %{id: id} do
      run(id, ~S|V.agent("> V.agent(\"deeper\")")|)
      assert_receive {:agent, {:job_end, %{id: "j1", tail: answer}}}, 5_000
      assert answer =~ "A sub-agent can't start sub-agents of its own"
    end

    test "meets as a council: members answer, one weighs them, the agent hears once", %{id: id} do
      script = ~S|V.council("list the files", roles: ["first", "second", "third"])|
      assert :ok = Agent.prompt(id, "> " <> script)

      assert_receive {:agent,
                      {:job_end, %{id: "j1", kind: :council, members: members} = council}},
                     10_000

      assert length(members) == 4
      assert council.tail =~ "Here is what came back"

      assert_receive {:agent, {:wake, notice}}, 5_000
      assert notice =~ "[Visor: council j1 (list the files) of 4 sub-agents answered"
      refute notice =~ "sub-agent j2"
      refute_receive {:agent, {:wake, _}}, 600

      assert run(id, ~S|V.council("x", roles: ["a", "b", "c", "d"])|) =~
               "A council has at most 3 roles"
    end

    # pi-fabric's members and synthesizer have only read-only tools; here
    # they had all of V, and members at work on one task could change the
    # same files under each other.
    test "keeps a council to reading, and weighs only the answers that came back",
         %{id: id, tmp_dir: tmp_dir} do
      script = ~S|V.council(~s[> V.write("x.txt", "y")], roles: ["first"], synthesize: false)|
      assert run(id, script) =~ ~s(=> %{job: "j1"})

      assert_receive {:agent, {:job_end, %{id: "j1", kind: :council, status: :exited} = c}},
                     10_000

      assert c.tail =~ "V.write isn't open to a council member"
      refute File.exists?(Path.join(tmp_dir, "x.txt"))

      # With the session's jobs all but taken, the second member can't
      # start: the first one's answer comes back alone, unweighed.
      for _ <- 1..6, do: run(id, ~S|V.sh("sleep 5", background: true)|)
      run(id, ~S|V.council("list the files", roles: ["a", "b"])|)
      assert_receive {:agent, {:job_end, %{kind: :council, members: [_one]} = c}}, 10_000
      assert c.tail =~ ~r/\A## a\n\nHere is what came back/
      assert c.tail =~ "No answer from: b (8 jobs are running already"
    end

    test "stops its members when it is stopped", %{id: id} do
      # Members only read, so they are stopped in a model call, not a command.
      run(id, ~S|V.council("SLOWREPLY list the files", roles: ["a", "b"], synthesize: false)|)
      assert_receive {:agent, {:job_start, %{id: "j2", child: first}}}, 5_000
      assert_receive {:agent, {:job_start, %{id: "j3", child: second}}}, 5_000
      await_turn(first)
      await_turn(second)

      assert run(id, ~S|V.stop("j1").status|) =~ "=> :killed"
      assert_receive {:agent, {:job_end, %{id: "j2", status: :killed}}}, 5_000
      assert_receive {:agent, {:job_end, %{id: "j3", status: :killed}}}, 5_000
    end

    test "ends when it is stopped, or when its parent's session ends", %{id: id} do
      run(id, ~S|V.agent("$ sleep 5")|)
      assert_receive {:agent, {:job_start, %{id: "j1", child: first}}}, 5_000
      ref = Process.monitor(session_pid(first))
      # Stopped after its first model call: that call still counts.
      await_tool(first)
      assert run(id, ~S|V.stop("j1").status|) =~ "=> :killed"
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
      assert_receive {:agent, {:job_end, %{id: "j1", totals: %{turns: 1}}}}, 5_000

      run(id, ~S|V.agent("$ sleep 5")|)
      assert_receive {:agent, {:job_start, %{id: "j2", child: second}}}, 5_000
      await_tool(second)
      ref = Process.monitor(session_pid(second))
      stop_supervised!(:session)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
      assert Registry.lookup(Visor.Harness.Registry, {second, :agent}) == []
    end
  end
end
