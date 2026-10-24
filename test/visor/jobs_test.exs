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
    assert :ok = Agent.prompt(id, ~S|> V.sh("sleep 5", background: true)|)
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000

    %{"content" => result} =
      Enum.find(:sys.get_state(agent(id)).messages, &(&1["role"] == "tool"))

    assert result =~ "[Visor: running in the background: j1 (sleep 5). Don't poll them"
    run(id, ~S|V.stop("j1")|)
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
end
