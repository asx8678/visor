defmodule Visor.HistoryTest do
  use ExUnit.Case, async: false

  alias Visor.{Code, History}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    logs = Path.join(tmp_dir, "logs")
    project = Path.join(tmp_dir, "project")
    File.mkdir_p!(logs)
    File.mkdir_p!(project)

    previous =
      {Application.get_env(:visor, :session_log_dir), Application.get_env(:visor, :workspace)}

    Application.put_env(:visor, :session_log_dir, logs)
    Application.put_env(:visor, :workspace, project)

    on_exit(fn ->
      Application.put_env(:visor, :session_log_dir, elem(previous, 0))
      Application.put_env(:visor, :workspace, elem(previous, 1))
    end)

    log(logs, "2026-10-20T100000-aaa111", project, nil, [
      %{event: "user", text: "fix the parser bug in lib/parser.ex"},
      %{event: "code_call", text: ~s|edit("lib/parser.ex")|, status: "ok"},
      %{
        event: "turn_end",
        finish_reason: "stop",
        content: "Fixed the parser: it dropped the last token."
      }
    ])

    log(logs, "2026-10-21T100000-bbb222", project, nil, [
      %{event: "user", text: "the parser again"}
    ])

    log(logs, "2026-10-22T100000-ccc333", "/somewhere/else", nil, [
      %{event: "user", text: "parser bug"}
    ])

    log(logs, "2026-10-20T110000-ddd444", "/somewhere/else", "aaa111/j1", [
      %{event: "script_end", status: "error", message: "** (MatchError) parser tokens"}
    ])

    :ok
  end

  defp log(dir, name, workspace, parent, events) do
    session = name |> String.split("-") |> List.last()
    start = %{event: "start", session: session, workspace: workspace, parent: parent}
    lines = for event <- [start | events], do: Jason.encode!(Map.put(event, :at, name))
    File.write!(Path.join(dir, name <> ".jsonl"), Enum.join(lines, "\n") <> "\n")
  end

  test "finds what this project's sessions said and did, best match first" do
    hits = History.search("parser bug")

    assert [%{session: "aaa111", kind: :prompt, ref: "aaa111:2"} | rest] = hits
    # One word each after that, the newest session first.
    assert [%{session: "bbb222"} | _] = rest
    kinds = hits |> Enum.map(& &1.kind) |> Enum.sort()
    assert kinds == Enum.sort([:prompt, :prompt, :call, :answer, :failure])

    # Not another project's, but a sub-agent of this one's.
    refute Enum.any?(hits, &(&1.session == "ccc333"))
    assert Enum.any?(hits, &(&1.session == "ddd444" and &1.kind == :failure))
  end

  test "reads a hit back in full, through V" do
    assert {:ok, "Fixed the parser: it dropped the last token."} = History.entry("aaa111:4")
    assert {:error, _message} = History.entry("ccc333:2")
    assert History.search("   ") == []

    script = ~S"""
    V.history("parser bug", limit: 1) |> hd() |> Map.get(:ref)
    """

    assert {:ok, text} = Code.run(script, %{})
    assert text =~ ~s(=> "aaa111:2")
    assert {:ok, text} = Code.run(~S|V.history_entry("aaa111:2")|, %{})
    assert text =~ "fix the parser bug in lib/parser.ex"
  end
end
