defmodule Visor.Example.Report do
  @moduledoc """
  `mix visor.example`'s `report.md`: the run (Visor, the model, where its
  logs are), a table of the checks, and each check with its steps: the
  scripts and prompts, what came back, the scripts the model ran, what it
  said, and what each prompt used.
  """

  import Visor.Example.Run, only: [mark: 1, verdict_text: 1, excerpt: 2, duration: 1]

  @doc "The report of `run`, whose checks gave `results`."
  @spec markdown(map(), [map()], [{String.t(), String.t()}]) :: String.t()
  def markdown(run, results, sessions) do
    c = counts(results)
    info = run.model
    rel = &Path.relative_to(&1, run.root)

    sessions_dir = rel.(Visor.SessionLog.dir() || "log/sessions")
    server_dir = rel.(Visor.ServerLog.dir() || "log/server")

    [
      "# Visor example run #{run.stamp}\n\n",
      if(Map.get(run, :ended?, true),
        do: "",
        else:
          "**Incomplete:** written after each check while the run went on; a run stopped " <>
            "before its end leaves it so.\n\n"
      ),
      "**#{c.passed} passed, #{c.failed} failed, #{c.skipped} skipped** in ",
      "#{duration(run.ms)}\n\n",
      "- Visor: #{Map.get_lazy(run, :git, fn -> git(run.root) end)}; ",
      "Elixir #{System.version()}, OTP #{System.otp_release()}\n",
      "- Model: #{info[:provider]} `#{info[:model]}` at `#{info[:endpoint]}`, key from ",
      "`#{inspect(info[:key])}` (never logged)\n",
      "- The example's copies: `#{run.copies}/`\n",
      "- Every event of every session: `#{rel.(Path.join(run.out, "events.jsonl"))}`\n",
      "- Server log: `mix visor.log server --dir #{server_dir}`\n",
      "- Session logs (`mix visor.log ID --full --dir #{sessions_dir}`):\n",
      for {id, label} <- sessions do
        logs =
          Path.join(Visor.SessionLog.dir() || "log/sessions", "*-#{id}.jsonl")
          |> Path.expand(run.root)
          |> Path.wildcard()
          |> Enum.map_join(", ", &"`#{rel.(&1)}`")

        "  - #{label}: `#{id}` #{logs}\n"
      end,
      "\n| # | Phase | Check | Result | Time |\n|---|---|---|---|---|\n",
      for r <- results do
        "| #{r.n} | #{r.phase} | #{r.name} | #{mark(r.verdict)} #{verdict_text(r.verdict)} | " <>
          "#{duration(r.ms)} |\n"
      end,
      for rs <- Enum.chunk_by(results, & &1.phase) do
        ["\n## #{hd(rs).phase}\n", Enum.map(rs, &check_section/1)]
      end
    ]
    |> IO.iodata_to_binary()
  end

  @doc "How many checks passed, failed and were skipped."
  def counts(results) do
    %{
      passed: Enum.count(results, &(&1.verdict == :pass)),
      failed: Enum.count(results, &match?({:fail, _}, &1.verdict)),
      skipped: Enum.count(results, &match?({:skip, _}, &1.verdict))
    }
  end

  defp check_section(r) do
    [
      "\n### #{r.n}. #{r.name}: #{mark(r.verdict)} #{verdict_text(r.verdict)}\n\n",
      r.what,
      "\n",
      case r.verdict do
        {:fail, why} -> "\n**Why it failed:** #{why}\n"
        _other -> ""
      end,
      Enum.map(r.steps, &step_section/1)
    ]
  end

  defp step_section(%{kind: :script} = s) do
    [
      "\n**Script** (#{s.status}, #{duration(s.ms)})\n\n",
      fence("elixir", s.input),
      "\n**Result**\n\n",
      fence("", excerpt(s.output, 3_000)),
      events_line(s.events)
    ]
  end

  defp step_section(%{kind: :prompt} = s) do
    t = s.totals
    pictures = if s.pictures == [], do: "", else: " with #{Enum.join(s.pictures, ", ")}"

    [
      "\n**Prompt**#{pictures} (#{inspect(s.status)}, #{duration(s.ms)}: #{t.turns} model ",
      "calls, #{t.tool_calls} scripts, #{t.v_calls} V calls, ",
      "#{t.prompt_tokens + t.completion_tokens} tokens, #{cost_text(t)})\n\n",
      "> ",
      String.replace(s.input, "\n", "\n> "),
      "\n",
      for({:steer, text} <- s.events, do: "\n**Steered while it ran:** #{text}\n"),
      for(
        {:wake, text} <- s.events,
        do: ["\n**Woke on its own:**\n\n", fence("", excerpt(text, 1_500))]
      ),
      for({:prompt_end, info} <- s.events, do: "\n**Prompt ended:** `#{inspect(info)}`\n"),
      model_scripts(s.events),
      "\n**What the model said** (each model call's text, the last its answer)\n\n",
      fence("", excerpt(s.output, 4_000)),
      notes(s.events),
      events_line(s.events)
    ]
  end

  defp step_section(s) do
    kind =
      case s.kind do
        :command -> "Command"
        :wait -> "Waited"
        _read -> "Read"
      end

    [
      "\n**#{kind}:** `#{s.input}` (#{inspect(s.status)})\n\n",
      fence("", excerpt(s.output, 3_000)),
      events_line(s.events)
    ]
  end

  defp model_scripts(events) do
    ends = for {:tool_end, call} <- events, into: %{}, do: {call.id, call}

    scripts =
      for {:tool_start, call} <- events do
        done = Map.get(ends, call.id, %{})
        {Visor.Tools.script(call.arguments) || call.arguments, done[:status], done[:result] || ""}
      end

    case scripts do
      [] ->
        "\n**Scripts the model ran:** none\n"

      scripts ->
        [
          "\n**Scripts the model ran**\n",
          scripts
          |> Enum.with_index(1)
          |> Enum.map(fn {{code, status, result}, i} ->
            [
              "\n#{i}. #{inspect(status)}\n\n",
              fence("elixir", code),
              "\n",
              fence("", excerpt(result, 1_500))
            ]
          end)
        ]
    end
  end

  defp notes(events) do
    case for({:note, level, text} <- events, do: "- #{level}: #{text}\n") do
      [] -> ""
      notes -> ["\n**Notes**\n\n", notes]
    end
  end

  defp events_line([]), do: ""

  defp events_line(events) do
    counts =
      events
      |> Enum.frequencies_by(&elem(&1, 0))
      |> Enum.sort_by(fn {_kind, n} -> -n end)
      |> Enum.map_join(", ", fn {kind, n} -> "#{kind} ×#{n}" end)

    "\n*Events:* #{counts}\n"
  end

  # A gateway such as zro reports what a call cost; DeepSeek itself doesn't.
  defp cost_text(%{cost: cost, unpriced: unpriced}) when cost == 0 and unpriced > 0,
    do: "cost not reported"

  defp cost_text(%{cost: cost}), do: Visor.Format.dollars(cost)

  defp fence(lang, text), do: ["````#{lang}\n", String.trim_trailing(text || ""), "\n````\n"]

  @doc "Visor's commit, and whether it has uncommitted changes."
  def git(root) do
    with {rev, 0} <- System.cmd("git", ["rev-parse", "--short", "HEAD"], cd: root),
         {changes, 0} <- System.cmd("git", ["status", "--porcelain"], cd: root) do
      "`#{String.trim(rev)}`" <> if(changes == "", do: "", else: " with uncommitted changes")
    else
      _none -> "not a git checkout"
    end
  rescue
    _error -> "git isn't installed"
  end
end
