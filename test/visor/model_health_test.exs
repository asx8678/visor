defmodule Visor.ModelHealthTest do
  # BeamAgent's circuit breaker: failures in a row hold back what starts
  # model calls on its own.
  use ExUnit.Case, async: false

  alias Visor.{Agent, ModelHealth}

  setup do
    Application.put_env(:visor, :model_cooldown_ms, 60_000)
    :ok = ModelHealth.reset()

    on_exit(fn ->
      Application.put_env(:visor, :model_cooldown_ms, 0)
      ModelHealth.reset()
    end)
  end

  test "opens after three failures in a row, and a call that answers closes it" do
    ModelHealth.record(:error)
    ModelHealth.record(:error)
    assert ModelHealth.open() == nil

    ModelHealth.record(:error)
    assert ModelHealth.open() =~ "The model failed 3 times in a row, so for 60 s more"

    ModelHealth.record(:ok)
    assert ModelHealth.open() == nil
  end

  test "holds back sub-agents while it is open, not the user's prompts" do
    for _ <- 1..3, do: ModelHealth.record(:error)
    id = "health#{System.unique_integer([:positive])}"
    start_supervised!({Visor.Harness.Session, id: id, owner: self()})
    Agent.subscribe(id)

    assert {:error, text} = Visor.Code.run(~S|V.agent("x")|, %{session: id, call_id: "c1"})
    assert text =~ "The model failed 3 times in a row"

    assert :ok = Agent.prompt(id, "list the files")
    assert_receive {:agent, {:prompt_end, %{reason: :answered}}}, 5_000
    assert ModelHealth.open() == nil
  end
end
