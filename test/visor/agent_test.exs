defmodule Visor.AgentTest do
  # Uses the scripted demo model (see config/test.exs).
  use ExUnit.Case, async: false

  alias Visor.{Agent, Harness}

  # The demo model, with a context threshold a few big results pass.
  defmodule SmallThreshold do
    def info, do: Map.put(Visor.Model.Demo.info(), :compact_tokens, 30_000)
    def stream(request, emit), do: Visor.Model.Demo.stream(request, emit)
  end

  # The demo model, each call costing $0.40 as a gateway such as zro
  # reports it.
  defmodule Costly do
    def info, do: Visor.Model.Demo.info()

    def stream(request, emit) do
      with {:ok, result} <- Visor.Model.Demo.stream(request, emit) do
        {:ok,
         %{result | usage: %{"prompt_tokens" => 1_000, "completion_tokens" => 10, "cost" => 0.4}}}
      end
    end
  end

  setup do
    id = "t#{System.unique_integer([:positive])}"
    session = start_supervised!({Visor.Harness.Session, id: id, owner: self()})
    Agent.subscribe(id)
    %{id: id, session: session}
  end

  # A script whose value is 30 KB of text, cut to 24 KB for the model.
  @big ~S|> String.duplicate("line\n", 6_000)|

  defp ask(id, text) do
    assert :ok = Agent.prompt(id, text)
    assert_receive {:agent, {:tool_end, %{id: call_id}}}, 5_000
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000
    call_id
  end

  defp agent(id), do: GenServer.whereis(Harness.via({id, :agent}))

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

    # A later summary counts the cancelled call as failed.
    assert [%{status: :error, calls: []}] = Map.values(:sys.get_state(agent(id)).facts)
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

    for step <- 1..39 do
      assert_receive {:agent, {:turn_start, %{step: ^step, max_steps: 40}}}
      assert_receive {:agent, {:turn_end, %{finish_reason: "tool_calls"}}}
    end

    assert_receive {:agent, {:note, :info, "The next model call is the last of 40" <> _}}
    assert_receive {:agent, {:turn_start, %{step: 40}}}

    assert_receive {:agent, {:turn_end, %{finish_reason: "stop", final: %{content: report}}}}

    assert report =~
             "[Visor: this is the last model call for this prompt, and it can't run tools."

    assert_receive {:agent, {:prompt_end, %{reason: :step_limit, steps: 40}}}
    refute_received {:agent, {:turn_start, %{step: 41}}}
    # The prompt, 39 tool calls and their results, and the report.
    assert %{status: :idle, messages: 80} = Agent.settings(id)
  end

  test "steers a running prompt: the model gets the message after the running tools", %{id: id} do
    assert :ok = Agent.prompt(id, "$ sleep 1")
    assert_receive {:agent, {:tool_start, %{status: :running}}}, 1_000

    assert :queued = Agent.prompt(id, "list the files")
    assert_receive {:agent, {:steer, "list the files"}}
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000

    # The steer follows the batch's result, and the model acted on it.
    roles =
      for %{"role" => role} = message <- :sys.get_state(agent(id)).messages,
          do: {role, message["content"]}

    assert [_user, _call, {"tool", _}, {"user", "list the files"} | _] = roles
    refute_received {:agent, {:user, "list the files"}}
  end

  test "makes a message sent while the model answers the next prompt", %{id: id} do
    previous = Application.get_env(:visor, :demo_delay_ms)
    Application.put_env(:visor, :demo_delay_ms, 20)
    on_exit(fn -> Application.put_env(:visor, :demo_delay_ms, previous) end)

    assert :ok = Agent.prompt(id, "hello")
    assert_receive {:agent, {:turn_start, %{turn: 1}}}
    assert :queued = Agent.prompt(id, "list the files")

    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000
    assert_receive {:agent, {:user, "list the files"}}
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000
  end

  test "drops what was sent to a prompt the user stopped", %{id: id} do
    assert :ok = Agent.prompt(id, "$ sleep 5")
    assert_receive {:agent, {:tool_start, %{status: :running}}}, 1_000
    assert :queued = Agent.prompt(id, "and then this")

    assert :ok = Agent.interrupt(id)

    assert_receive {:agent,
                    {:note, :info, "Not sent, since the prompt was stopped: and then this"}}

    assert %{status: :idle} = Agent.settings(id)
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

  test "keeps the conversation when the feedback collector crashes", %{id: id} do
    ask(id, "list the files")
    %{messages: before} = Agent.settings(id)
    agent = agent(id)

    feedback = GenServer.whereis(Harness.via({id, :feedback}))
    ref = Process.monitor(feedback)
    Process.exit(feedback, :kill)
    assert_receive {:DOWN, ^ref, :process, ^feedback, :killed}

    assert agent(id) == agent
    assert %{messages: ^before} = Agent.settings(id)
  end

  test "carries on with the conversation after the agent crashes", %{id: id, session: session} do
    ask(id, "list the files")
    %{messages: before} = Agent.settings(id)

    agent = agent(id)
    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^agent, :killed}

    # The session restarts the agent before it handles anything else.
    _ = :sys.get_state(session)
    assert agent(id) != agent
    assert %{messages: ^before} = Agent.settings(id)
  end

  test "warns about a script run again unchanged, and then refuses it", %{id: id} do
    assert :ok = Agent.prompt(id, String.duplicate(">> V.exists?(\"mix.exs\")\n", 6))
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000

    results = for {:done, result} <- tool_events(), do: result
    assert [first, second, third, _fourth, fifth, sixth] = results
    refute first =~ "[Visor: this exact script"
    refute second =~ "[Visor: this exact script"
    assert third =~ "[Visor: this exact script has run 3 times in a row."
    assert fifth =~ "has run 5 times in a row."
    assert sixth =~ "Not run: this exact script already ran 5 times in a row"
    assert_received {:agent, {:repeat, %{count: 6, blocked: true}}}
  end

  test "counts a script the same in a code fence or out of one", %{id: id} do
    fenced = "```elixir\nV.ls()\n```"
    assert :ok = Agent.prompt(id, Enum.map_join(["V.ls()", fenced, "V.ls()"], "\n", &">> #{&1}"))
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000
    assert_received {:agent, {:repeat, %{count: 3, blocked: false}}}
  end

  test "counts only identical scripts back to back", %{id: id} do
    scripts = ["V.ls()", "V.ls()", ~S|V.exists?("lib")|, "V.ls()", "V.ls()"]
    assert :ok = Agent.prompt(id, Enum.map_join(scripts, "\n", &">> #{&1}"))
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000

    for {:done, result} <- tool_events(), do: refute(result =~ "[Visor: this exact script")
    refute_received {:agent, {:repeat, _}}
  end

  test "answers the calls an agent crash left running, and carries on", %{
    id: id,
    session: session
  } do
    assert :ok = Agent.prompt(id, ">> V.ls()\n>> V.sh(\"sleep 5\")")
    assert_receive {:agent, {:tool_start, %{id: first}}}, 5_000
    assert_receive {:agent, {:tool_end, %{id: ^first, status: :ok, result: listing}}}, 5_000
    assert_receive {:agent, {:tool_start, %{id: second, pid: pid}}} when is_pid(pid), 5_000
    refute second == first

    agent = agent(id)
    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^agent, :killed}
    _ = :sys.get_state(session)

    # The finished call keeps its result; the running one is answered.
    assert_receive {:agent, {:repair, %{reason: :restart, answered: 2, dropped: 0}}}

    # Its command goes on after the restart, so it isn't said not to have run.
    assert [_user, _calls, %{"content" => ^listing}, %{"content" => restarted}] =
             :sys.get_state(agent(id)).messages

    assert restarted =~ "No result: the agent restarted before this call finished. It may"

    # The demo model refuses unanswered calls, as DeepSeek does.
    assert :ok = Agent.prompt(id, "list the files")
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000
  end

  test "compacts the conversation on request and still recalls what it summarized", %{id: id} do
    first = ask(id, @big)
    ask(id, @big)
    %{messages: before} = Agent.settings(id)

    assert {:ok, %{reason: :manual, summarized: summarized}} = Agent.compact(id)
    assert_receive {:agent, {:compaction, %{reason: :manual, messages_after: left}}}
    assert summarized > 0 and left < before
    assert %{messages: ^left} = Agent.settings(id)

    # The summary goes first, and the summarized result is still there.
    assert :ok = Agent.prompt(id, ~s|> V.recall("#{first}")|)
    assert_receive {:agent, {:request, _turn, %{"last_messages" => _}}}
    assert_receive {:agent, {:tool_end, %{status: :ok, result: recalled}}}, 5_000
    assert recalled =~ "line\nline"
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000

    %{compaction: %{summary: summary}} = :sys.get_state(agent(id))
    assert summary =~ "[Visor compaction] Messages 1-#{summarized} of this conversation"
  end

  test "keeps what the model carries in every summary", %{id: id} do
    ask(id, @big)
    ask(id, @big)

    assert :ok = Agent.prompt(id, ~S|> V.carry(add: "auth_test.exs:40 still fails")|)
    assert_receive {:agent, {:carry, ["auth_test.exs:40 still fails"]}}, 5_000
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000

    assert {:ok, _info} = Agent.compact(id)
    ask(id, @big)
    ask(id, @big)
    assert {:ok, _info} = Agent.compact(id)

    %{compaction: %{summary: summary}} = :sys.get_state(agent(id))
    assert summary =~ "[Carry forward]\n- auth_test.exs:40 still fails"

    assert {:ok, []} = Agent.carry(id, :clear)
    assert {:error, "A carried item can't be empty."} = Agent.carry(id, {:add, " "})

    for n <- 1..16, do: assert({:ok, _items} = Agent.carry(id, {:add, "item #{n}"}))
    assert {:error, "The summary carries at most 16 items." <> _} = Agent.carry(id, {:add, "17"})
  end

  # Made mid-prompt, a compaction took the prompt it ran in, and a live
  # model said it saw no request outstanding.
  test "compacts when a script asks, once its prompt has ended, keeping the next as it is",
       %{id: id} do
    ask(id, @big)
    ask(id, @big)

    assert :ok = Agent.prompt(id, ~S|> V.compact("the setup is done")|)
    assert_receive {:agent, {:tool_end, %{status: :ok}}}, 5_000
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000
    refute_received {:agent, {:compaction, _}}

    assert :ok = Agent.prompt(id, "list the files")

    assert_receive {:agent, {:compaction, %{reason: :requested, request: "the setup is done"}}},
                   5_000

    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000

    # The cut is before the new prompt, which the model sees as it was.
    %{messages: messages, compaction: compaction} = :sys.get_state(agent(id))
    assert Enum.find_index(messages, &(&1["content"] == "list the files")) >= compaction.from
  end

  test "makes no compaction a script asks for when there is too little to sum up", %{id: id} do
    assert :ok = Agent.prompt(id, ~S|> V.compact("early")|)
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000

    assert :ok = Agent.prompt(id, "list the files")

    assert_receive {:agent, {:note, :info, "The compaction a script asked for (early)" <> _}},
                   5_000

    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000
    refute_received {:agent, {:compaction, _}}
    assert :sys.get_state(agent(id)).compact_request == nil
  end

  test "lets the model set its own reasoning for the rest of the prompt", %{id: id} do
    assert :ok = Agent.prompt(id, "> V.think(:off)")
    assert_receive {:agent, {:turn_start, %{turn: 1, thinking: true, effort: "high"}}}

    assert_receive {:agent,
                    {:note, :info, "The model set no thinking for the rest of this prompt."}}

    assert_receive {:agent, {:turn_start, %{turn: 2, thinking: false}}}, 5_000
    assert_receive {:agent, {:prompt_end, _}}, 5_000

    # The user's setting comes back with the next prompt.
    assert_receive {:agent, {:settings, %{think: nil, thinking: true}}}
    ask(id, "list the files")
    assert_received {:agent, {:turn_start, %{turn: 3, thinking: true}}}
  end

  test "runs a count of model calls down, and gives way to the user", %{id: id} do
    assert {:ok, %{think: %{turns: 1}}} = Agent.think(id, "max", 1)
    ask(id, "list the files")
    assert_received {:agent, {:turn_start, %{turn: 1, effort: "max"}}}
    assert_received {:agent, {:turn_start, %{turn: 2, effort: "high"}}}

    assert {:ok, _settings} = Agent.think(id, "low", nil)
    assert {:ok, %{think: nil, effort: "max"}} = Agent.configure(id, effort: "max")
    assert {:error, "The level is off, low, high or max" <> _} = Agent.think(id, "huge", nil)
  end

  @tag :tmp_dir
  test "an attempt whose call fails removes the file it made", %{
    id: id,
    tmp_dir: tmp_dir
  } do
    previous = Application.get_env(:visor, :workspace)
    Application.put_env(:visor, :workspace, tmp_dir)
    on_exit(fn -> Application.put_env(:visor, :workspace, previous) end)

    script = ~S|> V.attempt(fn -> V.write("a.txt", "x"); V.edit("a.txt", "nope", "y") end)|
    assert :ok = Agent.prompt(id, script)
    assert_receive {:agent, {:tool_end, %{status: :error, result: result}}}, 5_000
    assert result =~ "reverted: a.txt (the attempt failed)"
    assert_receive {:agent, {:prompt_end, _}}, 5_000
    refute File.exists?(Path.join(tmp_dir, "a.txt"))
  end

  @tag :tmp_dir
  test "resumes another session's conversation from its log", %{id: id, tmp_dir: dir} do
    previous = Application.get_env(:visor, :session_log_dir)
    Application.put_env(:visor, :session_log_dir, dir)
    on_exit(fn -> Application.put_env(:visor, :session_log_dir, previous) end)

    call = %{
      "id" => "c1",
      "type" => "function",
      "function" => %{"name" => "elixir", "arguments" => "{}"}
    }

    system = %{"role" => "system", "content" => "Be brief."}
    first = [system, %{"role" => "user", "content" => "list the files"}]
    # The second request sent only what the first didn't have.
    added = [
      %{"role" => "assistant", "content" => "", "tool_calls" => [call]},
      %{"role" => "tool", "tool_call_id" => "c1", "content" => "ok: 1 call"}
    ]

    lines = [
      %{event: "start", session: "old111"},
      # A call from before the log's last compaction: not in its requests.
      %{event: "tool_end", id: "c0", status: "ok", result: "ok: 1 call\n=> the old listing"},
      %{event: "request", turn: 1, messages_from: 0, messages: first, params: %{}, tools: []},
      %{event: "tool_end", id: "c1", status: "ok"},
      %{event: "code_call", call_id: "c1", n: 1, name: "ls", text: "ls()", status: "ok"},
      %{event: "request", turn: 2, messages_from: 2, messages: added, params: %{}, tools: "same"},
      %{event: "turn_end", turn: 2, finish_reason: "stop", content: "Here they are."},
      %{event: "carry", items: ["keep the old API"]}
    ]

    File.write!(
      Path.join(dir, "2026-10-20T100000-old111.jsonl"),
      Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n"
    )

    assert {:ok, 4} = Agent.resume(id, "old111")
    assert_receive {:agent, {:resumed, %{from: "old111", messages: 4}}}
    state = :sys.get_state(agent(id))
    assert List.last(state.messages) == %{"role" => "assistant", "content" => "Here they are."}
    assert state.carry == ["keep the old API"]
    assert %{"c1" => %{status: :ok, calls: [%{name: :ls}]}} = state.facts

    # The summary it starts with names calls whose results are only in the
    # log; recall found none of them.
    assert {:ok, "ok: 1 call\n=> the old listing"} = Agent.recall(id, "c0")
    assert {:ok, "ok: 1 call"} = Agent.recall(id, "c1")

    # The demo model refuses a conversation out of order, as DeepSeek does.
    ask(id, "list the files")
    assert {:error, "There is no session log for nope."} = Agent.resume(id, "nope")
  end

  # BeamAgent's guardrails and Vibe's budget: wakes, councils and
  # sub-agents multiply calls, and nothing stopped one that kept going.
  test "stops a prompt at its spending limit, and the session at its own", %{id: id} do
    previous = Application.get_env(:visor, :model_provider)
    Application.put_env(:visor, :model_provider, Costly)
    on_exit(fn -> Application.put_env(:visor, :model_provider, previous) end)

    assert {:ok, _} = Agent.configure(id, budget: {:prompt, 1.0})

    assert {:ok, %{limits: %{prompt: 1.0, session: 1.5}}} =
             Agent.configure(id, budget: {:session, 1.5})

    # A fourth call would pass the prompt's $1.
    assert :ok = Agent.prompt(id, "keep going")

    assert_receive {:agent,
                    {:note, :error, "This prompt has spent $1.20, its limit of $1.00" <> _}},
                   5_000

    assert_receive {:agent, {:prompt_end, %{reason: :budget, steps: 3}}}, 5_000

    assert :ok = Agent.prompt(id, "list the files")

    assert_receive {:agent,
                    {:note, :error, "This session has spent $1.60, its limit of $1.50" <> _}},
                   5_000

    assert_receive {:agent, {:prompt_end, %{reason: :budget, steps: 1}}}, 5_000

    # No sub-agent starts on what is left.
    assert {:error, text} = Visor.Code.run(~S|V.agent("x")|, %{session: id, call_id: "c9"})
    assert text =~ "reached its spending limit"
  end

  # Each script started empty, so a model read a file again in every step
  # that needed it; Vibe's eval keeps its values (Dune.Session here).
  test "keeps a prompt's variables from script to script, and says which", %{id: id} do
    assert :ok = Agent.prompt(id, ">> text = \"hello\"\n>> String.length(text)")
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000

    assert [_first, second] = for({:done, result} <- tool_events(), do: result)
    assert second =~ "=> 5"

    last_result =
      :sys.get_state(agent(id)).messages
      |> Enum.filter(&(&1["role"] == "tool"))
      |> List.last()

    assert last_result["content"] =~
             "[Visor: kept for this prompt's next scripts: text (string, 5 B).]"

    # The next prompt starts without them, and the error says why.
    assert :ok = Agent.prompt(id, "> String.length(text)")
    assert_receive {:agent, {:tool_end, %{status: :error, result: error}}}, 5_000
    assert error =~ "hint: text isn't set: a script keeps the variables"
    assert_receive {:agent, {:prompt_end, _}}, 5_000

    # Past their limit they are dropped, with a note.
    assert :ok = Agent.prompt(id, ~S|> big = String.duplicate("x", 21_000_000); :ok|)
    assert_receive {:agent, {:tool_end, %{result: dropped}}}, 10_000
    assert dropped =~ "passed 20 MB, so they were dropped"
    assert_receive {:agent, {:prompt_end, _}}, 5_000
    assert :sys.get_state(agent(id)).kept == nil
  end

  # BeamAgent's verifier catches a run that claims success without the
  # tools it needed; here, an answer after a change no check passed on.
  @tag :tmp_dir
  test "reminds the model once to check what it changed, then marks the answer unchecked",
       %{id: id, tmp_dir: dir} do
    previous = Application.get_env(:visor, :workspace)
    Application.put_env(:visor, :workspace, dir)
    on_exit(fn -> Application.put_env(:visor, :workspace, previous) end)
    File.write!(Path.join(dir, "mix.exs"), "")

    assert :ok = Agent.prompt(id, ~S|> V.write("lib/a.ex", "defmodule A do\nend\n")|)

    assert_receive {:agent,
                    {:note, :info, "Visor asked the model to check lib/a.ex before it answers."}},
                   5_000

    assert_receive {:agent, {:prompt_end, %{reason: :answered, unchecked: ["lib/a.ex"]}}}, 5_000

    reminders =
      for %{"role" => "user", "content" => text} <- :sys.get_state(agent(id)).messages,
          text =~ "[Visor: lib/a.ex changed in this prompt",
          do: text

    assert length(reminders) == 1

    # A doc's change needs no check, and a prompt that changed nothing gets
    # no reminder for an earlier one's.
    assert :ok = Agent.prompt(id, ~S|> V.write("NOTES.md", "x")|)
    assert_receive {:agent, {:prompt_end, info}}, 5_000
    refute Map.has_key?(info, :unchecked)
    refute_received {:agent, {:note, :info, "Visor asked the model" <> _}}
  end

  # A 16x16 red PNG, which DeepSeek's Flash, through zro, called "Red".
  @red_png Base.decode64!(
             "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII="
           )

  # BeamWeaver's DeepSeek guide: Flash reads images.
  @tag :tmp_dir
  test "shows the model a picture it asked for, with its next call", %{id: id, tmp_dir: dir} do
    previous = Application.get_env(:visor, :workspace)
    Application.put_env(:visor, :workspace, dir)
    on_exit(fn -> Application.put_env(:visor, :workspace, previous) end)
    File.write!(Path.join(dir, "red.png"), @red_png)
    File.write!(Path.join(dir, "notes.txt"), "not a picture")

    assert :ok = Agent.prompt(id, ~S|> V.image("red.png")|)
    assert_receive {:agent, {:note, :info, "The model looks at red.png."}}, 5_000
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000

    messages = :sys.get_state(agent(id)).messages

    assert [_prompt, _call, _result, %{"role" => "user", "content" => [text, image]}, answer] =
             messages

    assert text["text"] == ~s|[Visor: the picture V.image("red.png") showed.]|
    assert image["image_url"]["url"] =~ "data:image/png;base64,iVBORw0KGgo"
    assert answer["content"] =~ "I see 1 image(s)."

    # A picture counts as what it costs, not its base64; text isn't one.
    assert Visor.Compaction.estimate(Enum.at(messages, 3)) < 1_600
    assert :ok = Agent.prompt(id, ~S|> V.image("notes.txt")|)
    assert_receive {:agent, {:tool_end, %{status: :error, result: error}}}, 5_000
    assert error =~ "notes.txt isn't a PNG, JPEG, GIF or WebP picture."
  end

  # The model never saw the project's own instructions.
  @tag :tmp_dir
  test "carries the project's AGENTS.md or CLAUDE.md in the system prompt, cut to a size",
       %{tmp_dir: dir} do
    previous = Application.get_env(:visor, :workspace)
    Application.put_env(:visor, :workspace, dir)
    on_exit(fn -> Application.put_env(:visor, :workspace, previous) end)

    system = fn name ->
      id = "rules#{System.unique_integer([:positive])}"
      start_supervised!({Visor.Harness.Session, id: id, owner: self()}, id: name)
      :sys.get_state(agent(id)).system
    end

    refute system.(:none) =~ "instructions for working on it"

    File.write!(Path.join(dir, "CLAUDE.md"), "Use tabs.\n")

    assert system.(:claude) =~
             "The project's CLAUDE.md, its instructions for working on it:\n\nUse tabs."

    rules = "## Rules\n" <> String.duplicate("- keep it short\n", 1_000)
    File.write!(Path.join(dir, "AGENTS.md"), rules)
    text = system.(:agents)
    assert text =~ "The project's AGENTS.md, its instructions for working on it:\n\n## Rules\n"

    assert text =~
             ~s|- keep it short\n\n[Visor: the first 8,000 of 16,009 bytes; V.read("AGENTS.md") | <>
               "has the rest.]"

    refute text =~ "CLAUDE.md"
  end

  test "tells a script how full the context is", %{id: id} do
    ask(id, @big)
    assert :ok = Agent.prompt(id, ~S|> c = V.context(); {c.band, c.tokens > 0, c.threshold}|)
    assert_receive {:agent, {:tool_end, %{result: result}}}, 5_000
    assert result =~ "=> {:ok, true, 200000}"
  end

  test "has nothing to compact before the conversation starts", %{id: id} do
    assert {:error, :nothing} = Agent.compact(id)
  end

  test "compacts on its own once the context passes its threshold", %{id: id} do
    previous = Application.get_env(:visor, :model_provider)
    Application.put_env(:visor, :model_provider, SmallThreshold)
    on_exit(fn -> Application.put_env(:visor, :model_provider, previous) end)

    for _ <- 1..5, do: ask(id, @big)

    assert_received {:agent, {:compaction, %{reason: :threshold, kept: kept}}}
    assert kept > 0
  end

  test "gives a script that asks for more time a later deadline", %{id: id} do
    assert :ok = Agent.prompt(id, "timeout 300 > V.sh(\"sleep 5\")")
    assert_receive {:agent, {:tool_start, %{status: :running}}}, 1_000

    assert [%{deadline: 315_000} = tool] = Map.values(:sys.get_state(agent(id)).tools)
    send(agent(id), {:deadline, tool.task.ref})

    assert_receive {:agent,
                    {:tool_end, %{result: "Stopped: the script was still running after 315 s."}}}

    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000
  end

  test "stops a tool still running at its deadline and goes on", %{id: id} do
    assert :ok = Agent.prompt(id, "$ sleep 5")
    assert_receive {:agent, {:tool_start, %{status: :running}}}, 1_000

    [ref] = Map.keys(:sys.get_state(agent(id)).tools)
    send(agent(id), {:deadline, ref})

    assert_receive {:agent,
                    {:tool_end, %{status: :error, result: "Stopped: the script was" <> _}}}

    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000
  end
end
