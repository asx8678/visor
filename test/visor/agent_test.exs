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
