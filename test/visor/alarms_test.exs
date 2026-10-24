defmodule Visor.AlarmsTest do
  # Vibe's system alarms: while the machine is short of memory or disk,
  # nothing starts work on its own.
  use ExUnit.Case, async: false

  alias Visor.{Alarms, Code}

  setup do
    {:ok, _apps} = Application.ensure_all_started(:sasl)

    on_exit(fn ->
      :alarm_handler.clear_alarm(:system_memory_high_watermark)
      Alarms.check()
    end)

    id = "alarms#{System.unique_integer([:positive])}"
    start_supervised!({Visor.Harness.Session, id: id, owner: self()})
    %{id: id}
  end

  test "holds back background jobs and sub-agents while an alarm is on", %{id: id} do
    Alarms.subscribe()
    :alarm_handler.set_alarm({:system_memory_high_watermark, []})
    assert ["The machine is nearly out of memory"] = Alarms.check()
    assert_receive {:alarms, ["The machine is nearly out of memory"]}

    script = ~S|V.sh("true", background: true)|
    assert {:error, text} = Code.run(script, %{session: id, call_id: "c1"})
    assert text =~ "The machine is nearly out of memory, so nothing starts on its own"

    # A process using much of the memory isn't a reason.
    :alarm_handler.set_alarm({{:process_memory_high_watermark, self()}, []})
    assert ["The machine is nearly out of memory"] = Alarms.check()

    :alarm_handler.clear_alarm(:system_memory_high_watermark)
    :alarm_handler.clear_alarm({:process_memory_high_watermark, self()})
    assert [] = Alarms.check()
    assert_receive {:alarms, []}
    assert {:ok, started} = Code.run(script, %{session: id, call_id: "c2"})
    assert started =~ ~s(=> %{job: "j1")
  end
end
