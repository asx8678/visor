defmodule Visor.AgentTest do
  # Uses the scripted demo model (see config/test.exs).
  use ExUnit.Case, async: false

  alias Visor.Agent

  setup do
    id = "t#{System.unique_integer([:positive])}"
    start_supervised!({Visor.Harness.Session, id: id, owner: self()})
    Agent.subscribe(id)
    %{id: id}
  end

  test "runs the tool loop until the model answers", %{id: id} do
    assert :ok = Agent.prompt(id, "list the files")

    assert_receive {:agent, {:user, "list the files"}}
    assert_receive {:agent, {:turn_start, %{turn: 1, pid: model_task}}}
    assert is_pid(model_task)
    assert_receive {:agent, {:turn_end, %{turn: 1, finish_reason: "tool_calls"}}}
    assert_receive {:agent, {:tool_start, %{name: "elixir", status: :running}}}
    assert_receive {:agent, {:tool_end, %{name: "elixir", status: :ok, result: listing}}}
    assert listing =~ "mix.exs"

    assert_receive {:agent,
                    {:turn_end, %{turn: 2, finish_reason: "stop", final: %{content: answer}}}}

    assert answer =~ "mix.exs"
    assert_receive {:agent, {:status, :idle}}

    # user, assistant with tool call, tool result, final answer
    assert %{messages: 4} = Agent.settings(id)
  end

  test "cancels running tools and answers their calls", %{id: id} do
    assert :ok = Agent.prompt(id, "$ sleep 5")
    assert_receive {:agent, {:tool_start, %{name: "elixir", status: :running}}}, 1_000

    assert :ok = Agent.interrupt(id)
    assert_receive {:agent, {:tool_end, %{status: :error, result: "Cancelled."}}}
    assert_receive {:agent, {:prompt_end, %{reason: :interrupted}}}

    # user, assistant with tool call, the cancelled call's result
    assert %{status: :idle, messages: 3} = Agent.settings(id)
    assert {:error, :idle} = Agent.interrupt(id)
  end

  @tag :tmp_dir
  test "runs a batch's calls one at a time, in order", %{id: id, tmp_dir: tmp_dir} do
    previous = Application.get_env(:visor, :workspace)
    Application.put_env(:visor, :workspace, tmp_dir)
    on_exit(fn -> Application.put_env(:visor, :workspace, previous) end)
    File.write!(Path.join(tmp_dir, "notes.txt"), Enum.map_join(1..4, &"line#{&1}\n"))

    edits = for n <- 1..4, do: ~s|>> V.edit("notes.txt", "line#{n}\\n", "LINE#{n}\\n")|
    assert :ok = Agent.prompt(id, Enum.join(edits, "\n"))
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000

    # Each call ends before the next starts, so no edit writes over another.
    assert [:start, :done, :start, :done, :start, :done, :start, :done] =
             Enum.map(tool_events(), &elem(&1, 0))

    assert File.read!(Path.join(tmp_dir, "notes.txt")) == Enum.map_join(1..4, &"LINE#{&1}\n")
  end

  # Two console tabs on one project.
  @tag :tmp_dir
  test "keeps every edit when two sessions change one file at once", %{id: id, tmp_dir: tmp_dir} do
    previous = Application.get_env(:visor, :workspace)
    Application.put_env(:visor, :workspace, tmp_dir)
    on_exit(fn -> Application.put_env(:visor, :workspace, previous) end)
    File.write!(Path.join(tmp_dir, "notes.txt"), Enum.map_join(1..12, &"line#{&1}\n"))

    other = "t#{System.unique_integer([:positive])}"
    start_supervised!({Visor.Harness.Session, id: other, owner: self()}, id: :other)
    Agent.subscribe(other)

    edits = fn range ->
      Enum.map_join(range, "\n", &~s|>> V.edit("notes.txt", "line#{&1}\\n", "LINE#{&1}\\n")|)
    end

    assert :ok = Agent.prompt(id, edits.(1..6))
    assert :ok = Agent.prompt(other, edits.(7..12))
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000

    assert File.read!(Path.join(tmp_dir, "notes.txt")) == Enum.map_join(1..12, &"LINE#{&1}\n")
  end

  test "cancels a batch, answering the calls that hadn't started", %{id: id} do
    assert :ok = Agent.prompt(id, ~s|>> V.sh("sleep 5")\n>> V.ls()\n>> V.ls()|)
    assert_receive {:agent, {:tool_start, %{pid: pid}}}, 1_000
    assert is_pid(pid)

    assert :ok = Agent.interrupt(id)
    assert_receive {:agent, {:prompt_end, %{reason: :interrupted}}}

    # The running call is stopped; the two waiting start without a
    # process and end at once, and all three are answered.
    assert [
             {:done, "Cancelled."},
             {:start, nil},
             {:done, "Cancelled."},
             {:start, nil},
             {:done, "Cancelled."}
           ] = tool_events()

    # user, assistant with three tool calls, their three results
    assert %{status: :idle, messages: 5} = Agent.settings(id)
  end

  # The tool events received so far, in order: {:start, pid} and
  # {:done, result}.
  defp tool_events do
    receive do
      {:agent, {:tool_start, call}} -> [{:start, call.pid} | tool_events()]
      {:agent, {:tool_end, call}} -> [{:done, call.result} | tool_events()]
    after
      0 -> []
    end
  end

  test "spends the last model call on a report, with the tools off", %{id: id} do
    assert :ok = Agent.prompt(id, "keep going")

    for step <- 1..23 do
      assert_receive {:agent, {:turn_start, %{step: ^step, max_steps: 24}}}
      assert_receive {:agent, {:turn_end, %{finish_reason: "tool_calls"}}}
    end

    assert_receive {:agent, {:note, :info, "The next model call is the last of 24" <> _}}
    assert_receive {:agent, {:turn_start, %{step: 24}}}

    assert_receive {:agent, {:turn_end, %{finish_reason: "stop", final: %{content: report}}}}

    assert report =~
             "[Visor: this is the last model call for this prompt, and it can't run tools."

    assert_receive {:agent, {:prompt_end, %{reason: :step_limit, steps: 24}}}
    refute_received {:agent, {:turn_start, %{step: 25}}}
    # The prompt, 23 tool calls and their results, and the report.
    assert %{status: :idle, messages: 48} = Agent.settings(id)
  end

  test "rejects a prompt while one is running", %{id: id} do
    assert :ok = Agent.prompt(id, "show BEAM stats")
    assert {:error, :busy} = Agent.prompt(id, "again")
    assert_receive {:agent, {:status, :idle}}
  end

  test "validates settings", %{id: id} do
    assert {:ok, %{effort: "max", thinking: false}} =
             Agent.configure(id, effort: "max", thinking: false)

    assert_receive {:agent, {:settings, %{effort: "max"}}}

    assert {:error, "Effort must be one of low, high, max, not medium."} =
             Agent.configure(id, effort: "medium")
  end

  test "stops the session when its owner goes away" do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    id = "t#{System.unique_integer([:positive])}"
    session = start_supervised!({Visor.Harness.Session, id: id, owner: owner}, id: :owned)
    ref = Process.monitor(session)

    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^session, :shutdown}
  end

  test "warns when a request misses the cache it should have hit" do
    usage = fn hit -> %{"prompt_tokens" => 30_000, "prompt_cache_hit_tokens" => hit} end

    assert Agent.cache_warning(25_000, usage.(9_000)) ==
             "The cache served 9000 of this request's 30000 prompt tokens, but the previous " <>
               "request sent 25000. The start of the conversation changed, or the cache " <>
               "wasn't ready yet."

    # A hit on most of the previous prompt, a first request, a small
    # prompt and a provider without usage are all fine.
    assert Agent.cache_warning(25_000, usage.(24_000)) == nil
    assert Agent.cache_warning(nil, usage.(0)) == nil
    assert Agent.cache_warning(2_000, usage.(0)) == nil
    assert Agent.cache_warning(25_000, nil) == nil
  end
end
