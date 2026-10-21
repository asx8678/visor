defmodule Visor.SessionLogTest do
  # Uses the scripted demo model (see config/test.exs).
  use ExUnit.Case, async: false

  alias Visor.{Agent, Harness, SessionLog}

  @moduletag :tmp_dir

  defp events(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp find(events, name), do: Enum.find(events, &(&1["event"] == name))

  defp waiting, do: spawn(fn -> receive do: (:stop -> :ok) end)

  defp broadcast(id, event),
    do: Phoenix.PubSub.broadcast(Visor.PubSub, Agent.topic(id), {:agent, event})

  # Starts a log for a stand-in session with no agent, so the test can
  # send it any event.
  defp start_log(dir, opts \\ []) do
    id = "t#{System.unique_integer([:positive])}"
    owner = waiting()
    session = waiting()

    log =
      start_supervised!({SessionLog, [id: id, owner: owner, session: session, dir: dir] ++ opts})

    %{id: id, owner: owner, session: session, log: log, path: SessionLog.path(id)}
  end

  # Stops a process the test started and waits until it is gone.
  defp stop(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  # Waits until the log has handled every event sent so far.
  defp sync(log), do: _ = :sys.get_state(log)

  test "logs a session's prompt, turns and tool calls, and why it stopped", %{tmp_dir: dir} do
    owner = waiting()
    {:ok, id} = Harness.start_session(owner, log_dir: dir)
    Agent.subscribe(id)
    path = SessionLog.path(id)
    assert Path.dirname(path) == dir
    assert Path.basename(path) =~ ~r/^\d{4}-\d\d-\d\dT\d{6}-#{id}\.jsonl$/
    [{log, ^path}] = Registry.lookup(Visor.Harness.Registry, {id, :log})
    ref = Process.monitor(log)

    :ok = Agent.prompt(id, "list the files")
    assert_receive {:agent, {:turn_end, %{turn: 2, finish_reason: "stop"}}}
    assert_receive {:agent, {:status, :idle}}

    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^log, :normal}

    events = events(path)
    names = Enum.map(events, & &1["event"])

    assert hd(names) == "start"
    assert Enum.take(names, -2) == ["owner_down", "stop"]

    for name <- ~w(user turn_start stream turn_end tool_start tool_end status context),
        do: assert(name in names, "no #{name} line")

    assert %{"text" => "list the files"} = find(events, "user")

    assert %{"name" => "list_dir", "status" => "ok", "result" => listing} =
             find(events, "tool_end")

    assert listing =~ "mix.exs"
    assert %{"finish_reason" => "tool_calls", "tool_calls" => [_]} = find(events, "turn_end")

    assert %{"status" => "idle", "text" => "The console page closed or reloaded, so" <> _} =
             find(events, "owner_down")

    assert Enum.all?(events, &is_integer(&1["elapsed_ms"]))
    assert Enum.all?(events, &(&1["at"] =~ ~r/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}$/))
  end

  @tag :capture_log
  test "says when the page went away in the middle of a prompt", %{tmp_dir: dir} do
    %{id: id, owner: owner, session: session, log: log, path: path} = start_log(dir)
    tool = waiting()
    ref = Process.monitor(log)

    broadcast(id, {:status, :tools})

    broadcast(
      id,
      {:tool_start, %{id: "c1", name: "elixir", arguments: "{}", status: :running, pid: tool}}
    )

    stop(owner)
    sync(log)
    stop(session)
    assert_receive {:DOWN, ^ref, :process, ^log, :normal}

    events = events(path)
    assert events |> Enum.map(& &1["event"]) |> Enum.take(-2) == ["owner_down", "stop"]

    assert %{"status" => "tools", "running" => ["tool elixir c1"], "text" => text} =
             find(events, "owner_down")

    assert text =~ "while the session was busy (tools)"
  end

  test "leaves no file for a session that never ran a prompt", %{tmp_dir: dir} do
    %{owner: owner, session: session, log: log, path: path} = start_log(dir)
    ref = Process.monitor(log)

    stop(owner)
    stop(session)
    assert_receive {:DOWN, ^ref, :process, ^log, :normal}
    refute File.exists?(path)
  end

  test "records a stall with the stack of each busy process", %{tmp_dir: dir} do
    # The test sends the ticks itself; any quiet counts as a stall.
    %{id: id, log: log, path: path} = start_log(dir, tick_ms: :timer.hours(1), stall_after_ms: 0)
    tool = waiting()

    broadcast(id, {:status, :tools})
    broadcast(id, {:tool_start, %{id: "c1", name: "sh", arguments: "{}", pid: tool}})
    send(log, :tick)
    sync(log)

    assert %{"status" => "tools", "processes" => [process], "text" => "No event for" <> _} =
             path |> events() |> find("stall")

    assert %{"label" => "tool sh c1", "status" => "waiting", "stacktrace" => [_ | _]} = process
  end

  test "keeps logging events JSON can't hold as they are", %{tmp_dir: dir} do
    %{id: id, log: log, path: path} = start_log(dir)
    long = String.duplicate("x", 70_000)

    broadcast(id, {:something_new, self(), make_ref(), {:a, 1}, <<255, 0>>})

    broadcast(
      id,
      {:tool_end,
       %{id: "c1", name: "read_file", status: :ok, ms: 3, result: long, extra: <<255>>}}
    )

    # Still running after both, or this call would exit.
    sync(log)
    events = events(path)

    assert %{"term" => term} = find(events, "event")
    assert term =~ "{:something_new, #PID<"
    assert %{"result" => result} = find(events, "tool_end")
    assert result == String.duplicate("x", 65_536) <> "… [4464 more characters cut]"
  end
end
