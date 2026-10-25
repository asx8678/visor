defmodule Mix.Tasks.Visor.Example do
  @shortdoc "Runs Visor on the example app, checks what it does, and logs everything"

  @moduledoc """
  Runs Visor on `examples/todo_app`, a small Mix project with a bug in
  it, and checks that the harness does what it should. Everything it
  does is logged for you to read:

      $ mix visor.example             # the harness, then the model
      $ mix visor.example --offline   # no call to a real model

  Each phase works on a fresh copy of the example, under
  `visor-example-runs/STAMP/` in the system's temporary folder, so the
  example itself never changes. The copies of the newest #{5} finished
  runs are kept, and those of runs that never finished for a day (one may
  still be going on beside this one).

    * **offline** (`Visor.Example.Offline`): scripts run through the
      `elixir` tool as the model's would, with no model call: reading,
      searching, writing and editing; the workspace's refusals (`.env`,
      paths outside it, the sandbox, the key in a command's environment);
      the arguments' repairs; `V.check` failing on the bug and passing
      once it is fixed; `V.attempt` putting a wrong fix back; background,
      monitored and stopped jobs; pictures; docs, sources and call sites;
      notes, saved scripts and a prompt's variables; the session log.
      `mix precommit` runs these.
    * **loop** (`Visor.Example.Loop`): the agent's own loop, with the
      scripted model (`Visor.Example.ScriptedModel`) in place of
      DeepSeek for this phase alone: steering, Stop, the spending limit,
      a sub-agent's spending and a slow parent, wakes, the repeat guard,
      compaction, a request too long for the window and malformed tool
      arguments. `mix precommit` runs these too.
    * **live** (`Visor.Example.Live`): prompts to the real model (the
      DeepSeek settings in Visor's `.env`), each held to `--budget`
      dollars: it fixes the bug and checks it while a steering message
      comes in; a background job wakes it when it ends; it reads a
      picture the user sends, and the same picture again in a later
      prompt; a sub-agent's tokens count in its parent's.

  It writes, under `log/example/STAMP/` (the newest #{20} runs are kept):

    * `report.md` (`Visor.Example.Report`): each check, passed or failed
      and why, with its scripts or prompts, what came back, the scripts
      the model ran and what each prompt used. Written again after each
      check, marked incomplete until the run ends, so a run stopped by
      hand leaves what it found.
    * `events.jsonl` (`Visor.Example.Recorder`): every event of every
      session from its first, sub-agents' too, and the run's own steps
    * for an offline run (`mix precommit`'s), its session logs in
      `sessions/` and its server log in `server/`, where a live run's go
      to `log/sessions/` and `log/server/` as always (`mix visor.log ID
      --full --dir DIR`)

  The task exits with 1 when a check fails.

  Options: `--offline`; `--budget DOLLARS`, each live prompt's limit
  (0.50); `--timeout SECONDS`, how long a live prompt may take (300).
  It lives in `dev/`, so it isn't part of a release.
  """

  use Mix.Task

  alias Visor.Example.{Live, Loop, Offline, Recorder, Report, Run, ScriptedModel}

  @runs_kept 5
  @unfinished_hours 24
  @reports_kept 20

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args, strict: [offline: :boolean, budget: :float, timeout: :integer])

    root = File.cwd!()
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%dT%H%M%S")
    out = Path.join([root, "log", "example", stamp])
    runs = Path.join(System.tmp_dir!(), "visor-example-runs")
    live? = not Keyword.get(opts, :offline, false)
    started = System.monotonic_time(:millisecond)

    prune_copies(runs)
    prune_reports(Path.dirname(out))
    # Before the workspace moves to the example's copy, whose .env isn't
    # Visor's: the model's settings come from Visor's.
    if live?, do: load_model_settings(root)
    # An offline run, mix precommit's, keeps its logs in its own folder.
    unless live? do
      Application.put_env(:visor, :session_log_dir, Path.join(out, "sessions"))
      Application.put_env(:visor, :server_log_dir, Path.join(out, "server"))
    end

    Mix.Task.run("app.start")
    # Again, should the app have started before this task with the default.
    unless live?, do: Visor.ServerLog.install()
    {:ok, recorder} = Recorder.start_link(Path.join(out, "events.jsonl"))

    run = %{
      root: root,
      out: out,
      stamp: stamp,
      copies: Path.join(runs, stamp),
      recorder: recorder,
      budget: Keyword.get(opts, :budget, 0.5),
      timeout: Keyword.get(opts, :timeout, 300) * 1000,
      model: model_info(),
      git: Report.git(root),
      started: started,
      ended?: false
    }

    Run.say("Visor example run #{stamp}\nlogs: #{Path.relative_to(out, root)}")
    Recorder.note(recorder, "run_start", %{stamp: stamp, live: live?, model: run.model})
    write_report(run, [])
    offline = Run.phase(run, :offline, Offline.checks(), &write_report(run, &1))

    loop =
      with_scripted_model(fn ->
        Run.phase(run, :loop, Loop.checks(), &write_report(run, offline ++ &1))
      end)

    done = offline ++ loop

    live =
      cond do
        not live? ->
          [Run.skipped(:live, "--offline: no model call was made.")]

        run.model[:key] == :none ->
          [Run.skipped(:live, "No DEEPSEEK_API_KEY anywhere Visor looks.")]

        true ->
          Run.phase(run, :live, Live.checks(), &write_report(run, done ++ &1))
      end

    results = done ++ live
    counts = Report.counts(results)
    Recorder.note(recorder, "run_end", counts)
    Recorder.sync(recorder)
    report = write_report(%{run | ended?: true}, results)
    # The copies of a run that ended, which a later run may remove.
    File.mkdir_p!(run.copies)
    File.write!(Path.join(run.copies, "done"), stamp)

    Run.say("\n#{counts.passed} passed, #{counts.failed} failed, #{counts.skipped} skipped")
    Run.say("report: #{Path.relative_to(report, root)}")
    Run.say("events: #{Path.relative_to(Path.join(out, "events.jsonl"), root)}")

    if counts.failed > 0,
      do:
        Mix.raise("#{counts.failed} example checks failed: see #{Path.relative_to(report, root)}")
  end

  # The loop phase's model is the scripted one, named for that phase
  # alone. Its jobs' wakes batch for 100 ms, and its scripted failures
  # hold nothing back afterwards (Visor.ModelHealth).
  defp with_scripted_model(fun) do
    {:ok, _pid} = ScriptedModel.start_link()
    keys = [:model_provider, :job_wake_batch_ms, :model_cooldown_ms]
    saved = for key <- keys, do: {key, Application.fetch_env(:visor, key)}
    Application.put_env(:visor, :model_provider, ScriptedModel)
    Application.put_env(:visor, :job_wake_batch_ms, 100)
    Application.put_env(:visor, :model_cooldown_ms, 0)

    try do
      fun.()
    after
      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:visor, key, value)
          :error -> Application.delete_env(:visor, key)
        end
      end
    end
  end

  # The report as the run stands: written whole beside it, then renamed
  # over it, so a run killed while it writes leaves the one before.
  defp write_report(run, results) do
    path = Path.join(run.out, "report.md")
    run = Map.put(run, :ms, System.monotonic_time(:millisecond) - run.started)
    File.mkdir_p!(run.out)
    File.write!(path <> ".tmp", Report.markdown(run, results, Recorder.sessions(run.recorder)))
    File.rename!(path <> ".tmp", path)
    path
  end

  # The newest finished runs' copies stay, for a look at what the model
  # did. One without its `done` may be a run going on beside this one, or
  # one stopped by hand: its copies go a day on.
  defp prune_copies(runs) do
    with {:ok, names} <- File.ls(runs) do
      {done, unfinished} = Enum.split_with(names, &File.exists?(Path.join([runs, &1, "done"])))
      stale = Enum.filter(unfinished, &older_than?(Path.join(runs, &1), @unfinished_hours))

      done
      |> Enum.sort(:desc)
      |> Enum.drop(@runs_kept - 1)
      |> Enum.concat(stale)
      |> Enum.each(&File.rm_rf(Path.join(runs, &1)))
    end
  end

  # The newest runs' reports and logs stay: mix precommit makes one each
  # time. Only folders named as runs are.
  defp prune_reports(dir) do
    with {:ok, names} <- File.ls(dir) do
      names
      |> Enum.filter(&(&1 =~ ~r/^\d{4}-\d\d-\d\dT\d{6}$/))
      |> Enum.sort(:desc)
      |> Enum.drop(@reports_kept - 1)
      |> Enum.each(&File.rm_rf(Path.join(dir, &1)))
    end
  end

  defp older_than?(path, hours) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> System.os_time(:second) - mtime > hours * 3600
      {:error, _reason} -> false
    end
  end

  defp model_info do
    Visor.Model.current().info()
  rescue
    _error -> %{}
  end

  # Visor's own DEEPSEEK_ settings, as the model reads them, for a run
  # whose workspace is elsewhere. Read here, never shown or logged, and
  # kept from shell commands (Visor.Tools.shell/2).
  defp load_model_settings(root) do
    with {:ok, text} <- File.read(Path.join(root, ".env")) do
      for line <- String.split(text, "\n"),
          [_, name, value] <- [
            Regex.run(~r/^\s*(?:export\s+)?(DEEPSEEK_\w+)\s*=\s*(.*?)\s*$/, line)
          ],
          System.get_env(name) in [nil, ""],
          do: System.put_env(name, value |> String.trim("\"") |> String.trim("'"))
    end

    :ok
  end
end
