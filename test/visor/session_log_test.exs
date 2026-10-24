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
    do: Visor.Agent.Event.broadcast(id, event)

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

  defp turn_start(turn) do
    %{
      turn: turn,
      step: turn,
      max_steps: 24,
      provider: %{model: "flash"},
      effort: "high",
      thinking: true,
      messages: turn,
      pid: self()
    }
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

    # The agent sends the conversation's size after it goes idle. Once it
    # answers a call it has sent that, and once the log answers one the log
    # has written it, so the owner's exit comes after it.
    _ = Agent.settings(id)
    sync(log)

    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^log, :normal}

    events = events(path)
    names = Enum.map(events, & &1["event"])

    assert hd(names) == "start"
    assert Enum.take(names, -3) == ["owner_down", "summary", "stop"]

    for name <- ~w(user turn_start stream turn_end tool_start tool_end status context prompt_end),
        do: assert(name in names, "no #{name} line")

    assert %{"text" => "list the files", "prompt" => 1} = find(events, "user")
    assert %{"step" => 1, "max_steps" => 24} = find(events, "turn_start")

    assert %{"prompt" => 1, "reason" => "answered", "steps" => 2, "turns" => 2, "tool_calls" => 1} =
             find(events, "prompt_end")

    assert %{"prompts" => 1, "endings" => %{"answered" => 1}, "turns" => 2} =
             find(events, "summary")

    assert %{"name" => "elixir", "status" => "ok", "result" => listing} =
             find(events, "tool_end")

    assert listing =~ "mix.exs"
    assert %{"finish_reason" => "tool_calls", "tool_calls" => [_]} = find(events, "turn_end")

    assert %{"status" => "idle", "text" => "The console page closed or reloaded, so" <> _} =
             find(events, "owner_down")

    assert Enum.all?(events, &is_integer(&1["elapsed_ms"]))
    assert Enum.all?(events, &(&1["at"] =~ ~r/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}$/))
  end

  @tag :capture_log
  test "says a closed page's session is kept, with a grace period", %{tmp_dir: dir} do
    Application.put_env(:visor, :session_grace_ms, 60_000)
    on_exit(fn -> Application.put_env(:visor, :session_grace_ms, 0) end)
    %{id: id, owner: owner, log: log, path: path} = start_log(dir)

    broadcast(id, {:status, :idle})
    stop(owner)
    sync(log)

    assert %{"text" => text} = find(events(path), "owner_down")
    assert text =~ "the session is kept for 1 min 0 s for a page to come back to it"
  end

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

    assert events |> Enum.map(& &1["event"]) |> Enum.take(-3) ==
             ["owner_down", "summary", "stop"]

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

  test "keeps logging events JSON can't hold as they are, and cuts nothing", %{tmp_dir: dir} do
    %{id: id, log: log, path: path} = start_log(dir)
    long = String.duplicate("x", 200_000)

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
    assert %{"result" => ^long} = find(events, "tool_end")
  end

  # A picture's base64 in the log made it too big for V.history to read.
  test "leaves a picture's bytes out of the log, and a resume puts text in its place",
       %{tmp_dir: dir} do
    %{id: id, log: log, path: path} = start_log(dir)
    picture = Visor.Content.image("image/png", :binary.copy(<<0x89, "PNG">>, 250_000))
    message = %{"role" => "user", "content" => [%{"type" => "text", "text" => "look"}, picture]}

    body = %{
      model: "flash",
      messages: [%{role: "system", content: "Be brief."}, message],
      tools: []
    }

    broadcast(id, {:wire_request, 1, %{url: "https://gateway.test", body: body}})
    sync(log)

    [request] = for %{"event" => "request"} = event <- events(path), do: event
    [_system, %{"content" => [_text, logged]}] = request["messages"]
    assert logged["image_url"]["url"] == "omitted: image/png, 1,000,000 bytes"
    assert File.stat!(path).size < 10_000

    assert %{"content" => [%{"type" => "text", "text" => "look[image left out]"}]} =
             Visor.Content.restore_omitted(%{
               "content" => [%{"type" => "text", "text" => "look"}, logged]
             })
  end

  test "writes each request's new messages, and the response", %{tmp_dir: dir} do
    %{id: id, log: log, path: path} = start_log(dir)
    url = "https://gateway.test/v1/chat/completions"
    params = %{model: "flash", stream: true}
    tools = [%{type: "function", function: %{name: "elixir"}}]
    system = %{role: "system", content: "Be brief."}
    hi = %{"role" => "user", "content" => "hi"}
    reply = %{"role" => "assistant", "content" => "hello"}
    again = %{"role" => "user", "content" => "again"}

    request = fn turn, messages ->
      broadcast(
        id,
        {:wire_request, turn,
         %{url: url, body: Map.merge(params, %{messages: messages, tools: tools})}}
      )
    end

    request.(1, [system, hi])
    broadcast(id, {:wire_response, 1, %{status: 200, headers: %{"x-request-id" => ["r1"]}}})
    request.(2, [system, hi, reply, again])
    # After the conversation is cleared, nothing carries over.
    request.(3, [system, again])
    broadcast(id, {:wire_response, 3, %{status: 400, headers: %{}, body: ~s|{"error":"bad"}|}})
    sync(log)

    requests = for %{"event" => "request"} = event <- events(path), do: event

    assert [
             %{"messages_from" => 0, "messages_total" => 2, "messages" => [_, ^hi]} = first,
             %{"messages_from" => 2, "messages" => [^reply, ^again], "tools" => "same as turn 1"},
             %{"messages_from" => 0, "messages" => [_, ^again], "tools" => "same as turn 1"}
           ] = requests

    assert %{"url" => ^url, "params" => %{"model" => "flash", "stream" => true}} = first
    assert [%{"function" => %{"name" => "elixir"}}] = first["tools"]

    body = Map.merge(params, %{messages: [system, hi], tools: tools})
    assert first["bytes"] == byte_size(Jason.encode!(body))

    assert [
             %{"turn" => 1, "status" => 200, "headers" => %{"x-request-id" => ["r1"]}},
             %{"turn" => 3, "status" => 400, "body" => ~s|{"error":"bad"}|}
           ] = for(%{"event" => "response"} = event <- events(path), do: event)
  end

  test "still writes why the session stopped when it can't sum it up", %{tmp_dir: dir} do
    %{id: id, session: session, log: log, path: path} = start_log(dir)
    ref = Process.monitor(log)
    broadcast(id, {:user, "first"})

    # State from before a hot reload added the totals, as in dev.
    :sys.replace_state(log, &Map.drop(&1, [:prompt, :totals]))
    stop(session)
    assert_receive {:DOWN, ^ref, :process, ^log, :normal}

    assert %{"term" => "summary", "error" => error} = find(events(path), "unrecorded")
    assert error =~ "key :prompt not found"
    assert %{"reason" => "normal"} = find(events(path), "stop")
  end

  test "sums up each prompt and the session", %{tmp_dir: dir} do
    %{id: id, owner: owner, session: session, log: log, path: path} = start_log(dir)
    ref = Process.monitor(log)

    usage = %{
      "prompt_tokens" => 1000,
      "prompt_cache_hit_tokens" => 800,
      "completion_tokens" => 50
    }

    broadcast(id, {:user, "first"})
    broadcast(id, {:turn_start, turn_start(1)})
    broadcast(id, {:turn_end, %{turn: 1, finish_reason: "tool_calls", usage: usage, ms: 900}})
    broadcast(id, {:tool_start, %{id: "c1", name: "elixir", arguments: "{}", pid: self()}})
    broadcast(id, {:code_call, "c1", %{n: 1, text: ~s|read("a")|, status: :running}})
    broadcast(id, {:code_call, "c1", %{n: 1, text: ~s|read("a")|, status: :ok, returned: "A"}})
    broadcast(id, {:code_call, "c1", %{n: 2, text: ~s|read("b")|, status: :error, error: "no"}})
    broadcast(id, {:tool_end, %{id: "c1", name: "elixir", status: :error, ms: 30, result: "no"}})
    broadcast(id, {:turn_start, turn_start(2)})
    broadcast(id, {:turn_end, %{turn: 2, finish_reason: "stop", usage: usage, ms: 600}})
    broadcast(id, {:prompt_end, %{reason: :answered, steps: 2}})

    # A second prompt still running when the session stops.
    broadcast(id, {:user, "second"})
    broadcast(id, {:note, :error, "DeepSeek returned HTTP 500."})
    stop(owner)
    sync(log)
    stop(session)
    assert_receive {:DOWN, ^ref, :process, ^log, :normal}

    events = events(path)

    assert [first, second] = for(%{"event" => "prompt_end"} = event <- events, do: event)

    assert %{
             "prompt" => 1,
             "reason" => "answered",
             "steps" => 2,
             "turns" => 2,
             "tool_calls" => 1,
             "tool_errors" => 1,
             "v_calls" => 2,
             "v_errors" => 1,
             "errors" => 0,
             "prompt_tokens" => 2000,
             "cached_tokens" => 1600,
             "completion_tokens" => 100,
             "model_ms" => 1500,
             "tool_ms" => 30
           } = first

    assert is_integer(first["ms"])
    assert %{"prompt" => 2, "reason" => "session_stopped", "turns" => 0, "errors" => 1} = second

    assert %{
             "prompts" => 2,
             "endings" => %{"answered" => 1, "session_stopped" => 1},
             "turns" => 2,
             "errors" => 1,
             "prompt_tokens" => 2000
           } = find(events, "summary")
  end
end
