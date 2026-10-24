defmodule Mix.Tasks.Visor.LogTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Visor.Log

  @moduletag :tmp_dir

  @totals %{
    turns: 1,
    tool_calls: 1,
    tool_errors: 0,
    v_calls: 1,
    v_errors: 0,
    errors: 0,
    prompt_tokens: 12_345,
    cached_tokens: 9000,
    completion_tokens: 678,
    reasoning_tokens: 0,
    model_ms: 6400,
    tool_ms: 0,
    request_bytes: 2048
  }

  @events [
    %{event: "start", session: "abc123", provider: "DeepSeek", model: "flash", workspace: "/w"},
    %{event: "user", prompt: 1, text: "make a website"},
    %{
      event: "turn_start",
      turn: 1,
      messages: 1,
      effort: "high",
      thinking: true,
      pid: "#PID<0.1.0>",
      step: 1,
      max_steps: 24
    },
    %{
      event: "request",
      turn: 1,
      url: "https://gw.test/v1/chat/completions",
      bytes: 2048,
      params: %{model: "flash", stream: true},
      messages_total: 2,
      messages_from: 0,
      messages: [
        %{role: "system", content: "Be brief."},
        %{role: "user", content: "make a website"}
      ],
      tools: [%{type: "function", function: %{name: "elixir"}}]
    },
    %{event: "response", turn: 1, status: 200, headers: %{"x-request-id" => ["r1"]}},
    %{
      event: "turn_end",
      turn: 1,
      finish_reason: "tool_calls",
      ms: 6400,
      ttft_ms: 1200,
      usage: %{prompt_tokens: 12_345, completion_tokens: 678, prompt_cache_hit_tokens: 9000},
      content: "",
      tool_calls: [%{id: "c1", name: "elixir", arguments: ~S|{"code":"V.write(\"a.css\", css)"}|}]
    },
    %{event: "tool_start", id: "c1", name: "elixir", pid: "#PID<0.2.0>"},
    %{event: "code_call", call_id: "c1", n: 1, text: ~s|write("a.css")|, status: "running"},
    %{event: "code_call", call_id: "c1", n: 1, text: ~s|write("a.css")|, status: "ok", ms: 2},
    %{event: "code_call", call_id: "c1", n: 2, text: ~s|sh("mix test")|, status: "running"},
    %{event: "repeat", id: "c1", count: 3, blocked: false},
    %{event: "repair", reason: "restart", answered: 2, dropped: 0},
    %{event: "job_start", id: "j1", label: "mix test", status: "running"},
    %{event: "job_end", id: "j1", label: "mix test", status: "failed", exit: 2, ms: 4200},
    %{event: "wake", text: "[Visor: background job j1 (mix test) failed with status 2]"},
    %{
      event: "owner_down",
      text: "The console page closed or reloaded while the session was busy (tools).",
      reason: "{:shutdown, :closed}",
      status: "tools",
      running: ["tool elixir c1"]
    },
    Map.merge(@totals, %{event: "prompt_end", prompt: 1, reason: "session_stopped", ms: 8000}),
    Map.merge(@totals, %{event: "summary", prompts: 1, endings: %{session_stopped: 1}, ms: 9000}),
    %{event: "stop", reason: "shutdown", status: "tools"}
  ]

  setup %{tmp_dir: dir} do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    lines =
      @events
      |> Enum.with_index()
      |> Enum.map(fn {event, i} ->
        Jason.encode!(Map.merge(%{at: "2026-10-21T19:03:1#{i}.000", elapsed_ms: i * 1000}, event))
      end)

    File.write!(Path.join(dir, "2026-10-21T190310-abc123.jsonl"), Enum.join(lines, "\n") <> "\n")
    :ok
  end

  defp output do
    receive do
      {:mix_shell, :info, [line]} -> line <> "\n" <> output()
    after
      0 -> ""
    end
  end

  test "lists sessions with how each ended", %{tmp_dir: dir} do
    Log.run(["--dir", dir])

    assert output() =~
             "2026-10-21T19:03:10  abc123  1 prompt, 1 turn, 1 tool call, 12,345 tokens in, " <>
               "678 out, 18s  page closed or reloaded while tools"
  end

  test "prints a session as a timeline", %{tmp_dir: dir} do
    Log.run(["abc123", "--dir", dir])
    out = output()

    assert out =~
             "19:03:11     +1.0s  prompt 1\n" <> String.duplicate(" ", 20) <> "make a website"

    assert out =~
             "tool_calls after 6.4s (first token 1.2s), 12,345 tokens in (9,000 cached), 678 out"

    # The script, not its JSON arguments.
    assert out =~ ~s|V.write("a.css", css)|
    # A finished call shows once; one still running shows as running.
    assert out |> String.split(~s|write("a.css")|) |> length() == 2
    assert out =~ ~s|sh("mix test") running|

    assert out =~
             "PAGE    The console page closed or reloaded while the session was busy (tools)."

    assert out =~ "running: tool elixir c1"

    assert out =~
             "turn 1  model call with 1 message, step 1 of 24, thinking on, effort high"

    assert out =~
             "request POST https://gw.test/v1/chat/completions, 2 messages (2 new), 2,048 bytes"

    assert out =~ "response HTTP 200"
    assert out =~ "done    prompt 1 unfinished when the session stopped after 8.0s"

    assert out =~
             "1 model call, 1 tool call, 1 V call, 0 errors, 12,345 tokens in (9,000 cached), " <>
               "678 out, model 6.4s, tools 0.0s, 2,048 bytes sent"

    assert out =~ "repeat  the same script 3 times in a row, warned (c1)"
    assert out =~ "repair  2 tool calls answered, 0 stray results dropped (restart)"
    assert out =~ "job     j1 started: mix test"
    assert out =~ "job     j1 failed, exit 2 after 4.2s: mix test"
    assert out =~ "wake    [Visor: background job j1 (mix test) failed with status 2]"
    assert out =~ "summary 1 prompt (1 session_stopped) in 9.0s"
    assert out =~ "stop    session stopped (shutdown)"
  end

  test "puts a request back together from the lines that hold its parts", %{tmp_dir: dir} do
    system = %{"role" => "system", "content" => "Be brief."}
    tools = [%{"type" => "function", "function" => %{"name" => "elixir"}}]
    params = %{"model" => "flash", "stream" => true}

    requests = [
      # The first request, then one that adds a reply and a tool result,
      # then one after the conversation was cleared.
      {1, 0, [system, %{"role" => "user", "content" => "hi"}], tools},
      {2, 2, [%{"role" => "assistant", "content" => "A"}, %{"role" => "tool", "content" => "B"}],
       "same as turn 1"},
      {3, 0, [system, %{"role" => "user", "content" => "again"}], "same as turn 1"}
    ]

    lines =
      for {turn, from, messages, tools} <- requests do
        Jason.encode!(%{
          event: "request",
          turn: turn,
          params: params,
          messages_from: from,
          messages_total: from + length(messages),
          messages: messages,
          tools: tools
        })
      end

    File.write!(Path.join(dir, "2026-10-21T190400-def456.jsonl"), Enum.join(lines, "\n") <> "\n")

    Log.run(["def456", "--dir", dir, "--request", "2"])

    assert Jason.decode!(output()) ==
             Map.merge(params, %{
               "messages" => [
                 system,
                 %{"role" => "user", "content" => "hi"},
                 %{"role" => "assistant", "content" => "A"},
                 %{"role" => "tool", "content" => "B"}
               ],
               "tools" => tools
             })

    Log.run(["def456", "--dir", dir, "--request", "3"])

    assert %{"messages" => [^system, %{"content" => "again"}], "tools" => ^tools} =
             Jason.decode!(output())

    assert_raise Mix.Error, "No request for model call 9 in this log.", fn ->
      Log.run(["def456", "--dir", dir, "--request", "9"])
    end
  end

  test "shows which session a sub-agent's log belongs to", %{tmp_dir: dir} do
    line =
      Jason.encode!(%{
        at: "2026-10-22T10:00:00.000",
        event: "start",
        session: "kid1",
        parent: "abc123/j2"
      })

    File.write!(Path.join(dir, "2026-10-22T100000-kid1.jsonl"), line <> "\n")

    Log.run(["--dir", dir])
    assert output() =~ ~r/kid1 .*\(sub-agent of abc123\/j2\)/
  end

  test "counts the V calls scripts got wrong, by function", %{tmp_dir: dir} do
    lines = [
      %{event: "code_call", call_id: "c2", n: 1, text: ~s|read("a")|, status: "ok"},
      %{event: "code_call", call_id: "c2", n: 2, text: ~s|read("b")|, status: "error"},
      %{
        event: "script_end",
        call_id: "c3",
        status: "error",
        message: "** (UndefinedFunctionError) function V.read_file/1 is undefined or private"
      },
      %{
        event: "script_end",
        call_id: "c4",
        status: "error",
        message: "** (FunctionClauseError) no function clause matching in V.read/1"
      },
      %{event: "script_end", call_id: "c5", status: "error", message: "** (MatchError) no match"}
    ]

    File.write!(
      Path.join(dir, "2026-10-22T100000-def456.jsonl"),
      Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n"
    )

    Log.run(["stats", "--dir", dir])
    out = output()

    # The first session has 1 finished V call; this one 2, and 2 rejected.
    assert out =~ "2 sessions: 5 V calls, 2 rejected (400.0 per 1,000)"
    assert out =~ "V.read_file: 1 of 1 rejected"
    assert out =~ "V.read: 1 of 3 rejected"
  end

  test "reads the latest session", %{tmp_dir: dir} do
    Log.run(["latest", "--dir", dir])
    assert output() =~ "session abc123 started, DeepSeek flash, in /w"
  end

  test "prints a server log, leaving out what is less severe than --level", %{tmp_dir: dir} do
    dir = Path.join(dir, "server")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "2026-10-21T180000.jsonl"), "")

    lines = [
      %{at: "2026-10-21T19:00:00.001", level: "info", message: "Writing the server log"},
      %{
        at: "2026-10-21T19:00:01.250",
        level: "error",
        message: "GenServer Visor.Observer terminating\n** (RuntimeError) boom",
        pid: "#PID<0.1.0>",
        mfa: "Visor.Observer.handle_info/2",
        file: "lib/visor/observer.ex",
        line: 40,
        metadata: %{registered_name: "Visor.Observer"}
      }
    ]

    File.write!(
      Path.join(dir, "2026-10-21T190000.jsonl"),
      Enum.map_join(lines, &(Jason.encode!(&1) <> "\n")) <> "not json\n"
    )

    Log.run(["server", "--dir", dir, "--level", "warning"])
    out = output()
    refute out =~ "Writing the server log"

    assert out =~
             "19:00:01.250  error     GenServer Visor.Observer terminating\n" <>
               String.duplicate(" ", 24) <> "** (RuntimeError) boom\n"

    assert out =~ ~s|"not json\\n"|
    refute out =~ "lib/visor/observer.ex"

    Log.run(["server", "2026-10-21T19", "--dir", dir, "--full"])
    out = output()
    assert out =~ "19:00:00.001  info      Writing the server log"
    assert out =~ "at Visor.Observer.handle_info/2, lib/visor/observer.ex:40, #PID<0.1.0>"
    assert out =~ ~s|{"registered_name":"Visor.Observer"}|

    Log.run(["server", "2026-10-21T18", "--dir", dir])
    assert output() =~ "2026-10-21T180000.jsonl"

    assert_raise Mix.Error, ~r/No server log started at 2025/, fn ->
      Log.run(["server", "2025", "--dir", dir])
    end

    assert_raise Mix.Error, ~r/--level takes one of/, fn ->
      Log.run(["server", "--dir", dir, "--level", "loud"])
    end
  end
end
