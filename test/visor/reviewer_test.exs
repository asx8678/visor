defmodule Visor.ReviewerTest do
  # The demo model answers a review with a message when the digest says
  # PROBLEM, with the goal met when it says DONE, and with silence
  # otherwise (see test/support/model/demo.ex).
  use ExUnit.Case, async: false

  alias Visor.{Agent, Harness, Reviewer}

  setup do
    id = "r#{System.unique_integer([:positive])}"
    start_supervised!({Visor.Harness.Session, id: id, owner: self()})
    Agent.subscribe(id)
    %{id: id}
  end

  defp agent(id), do: GenServer.whereis(Harness.via({id, :agent}))

  test "is idle until turned on", %{id: id} do
    assert Reviewer.status(id) == nil
    assert :ok = Agent.prompt(id, "list the files PROBLEM")
    assert_receive {:agent, {:prompt_end, _}}, 5_000
    refute_receive {:agent, {:review, _}}, 300
  end

  test "an advisor keeps quiet while the work is on track", %{id: id} do
    :ok = Reviewer.start(id, :advisor, "")
    assert :ok = Agent.prompt(id, "list the files")
    assert_receive {:agent, {:review, %{mode: :advisor, action: :silent}}}, 5_000
    assert :sys.get_state(agent(id)).pending_texts == []
  end

  test "an advisor's advice reaches the next prompt and never starts one", %{id: id} do
    :ok = Reviewer.start(id, :advisor, "correctness")
    assert :ok = Agent.prompt(id, "list the files PROBLEM")

    assert_receive {:agent,
                    {:review, %{action: :message, message: "Look at the PROBLEM first."}}},
                   5_000

    refute_receive {:agent, {:wake, _}}, 600

    assert :ok = Agent.prompt(id, "list the files")
    assert_receive {:agent, {:prompt_end, _}}, 5_000

    assert Enum.any?(
             :sys.get_state(agent(id)).messages,
             &(&1["role"] == "user" and
                 &1["content"] =~ "list the files\n\n[Visor advisor: Look at the PROBLEM first.]")
           )
  end

  test "a supervisor starts the agent again, within the wake and review limits", %{id: id} do
    :ok = Reviewer.start(id, :supervisor, "the files are listed")
    assert :ok = Agent.prompt(id, "list the files PROBLEM")

    assert_receive {:agent, {:wake, "[Visor supervisor: Look at the PROBLEM first.]"}}, 5_000

    # Three reviews per prompt from the user, then quiet.
    for _ <- 1..3, do: assert_receive({:agent, {:review, %{mode: :supervisor}}}, 5_000)
    refute_receive {:agent, {:review, _}}, 600
  end

  test "a supervisor turns itself off once the goal is met", %{id: id} do
    :ok = Reviewer.start(id, :supervisor, "the files are listed")
    assert :ok = Agent.prompt(id, "list the files DONE")
    assert_receive {:agent, {:review, %{action: :stop}}}, 5_000
    assert Reviewer.status(id) == nil

    :ok = Reviewer.start(id, :advisor, "")
    :ok = Reviewer.stop(id)
    assert Reviewer.status(id) == nil
  end

  # The prompt's last call fails, and the prompt ends while that failure's
  # review runs: its end was dropped, so a supervisor never got to review
  # how the prompt ended.
  test "reviews a prompt's end that came while another review ran", %{id: id} do
    :ok = Reviewer.start(id, :advisor, "")
    assert :ok = Agent.prompt(id, ~S|> V.read("nope.txt") # SLOWREVIEW|)
    assert_receive {:agent, {:tool_end, %{status: :error}}}, 5_000
    assert_receive {:agent, {:prompt_end, _}}, 5_000
    refute_received {:agent, {:review, _}}

    assert_receive {:agent, {:review, %{mode: :advisor}}}, 5_000
    assert_receive {:agent, {:review, %{mode: :advisor}}}, 5_000
    refute_receive {:agent, {:review, _}}, 600
  end

  test "doesn't review what the user stopped", %{id: id} do
    :ok = Reviewer.start(id, :advisor, "")
    assert :ok = Agent.prompt(id, "$ sleep 5")
    assert_receive {:agent, {:tool_start, %{pid: pid}}} when is_pid(pid), 5_000
    assert :ok = Agent.interrupt(id)
    assert_receive {:agent, {:prompt_end, %{reason: :interrupted}}}
    refute_receive {:agent, {:review, _}}, 300
  end
end
