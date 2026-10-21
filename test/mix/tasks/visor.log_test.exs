defmodule Mix.Tasks.Visor.LogTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Visor.Log

  @moduletag :tmp_dir

  @events [
    %{event: "start", session: "abc123", provider: "DeepSeek", model: "flash", workspace: "/w"},
    %{event: "user", text: "make a website"},
    %{
      event: "turn_start",
      turn: 1,
      messages: 1,
      effort: "high",
      thinking: true,
      pid: "#PID<0.1.0>"
    },
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
    %{
      event: "owner_down",
      text: "The console page closed or reloaded while the session was busy (tools).",
      reason: "{:shutdown, :closed}",
      status: "tools",
      running: ["tool elixir c1"]
    },
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
             "2026-10-21T19:03:10  abc123  1 prompt, 1 turn, 1 tool call  " <>
               "page closed or reloaded while tools"
  end

  test "prints a session as a timeline", %{tmp_dir: dir} do
    Log.run(["abc123", "--dir", dir])
    out = output()

    assert out =~ "19:03:11     +1.0s  prompt\n" <> String.duplicate(" ", 20) <> "make a website"

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
    assert out =~ "stop    session stopped (shutdown)"
  end

  test "reads the latest session", %{tmp_dir: dir} do
    Log.run(["latest", "--dir", dir])
    assert output() =~ "session abc123 started, DeepSeek flash, in /w"
  end
end
