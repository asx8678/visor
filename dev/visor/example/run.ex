defmodule Visor.Example.Run do
  @moduledoc """
  What `mix visor.example`'s checks are made of: a phase (a fresh copy of
  the example and a session on it), the steps a check takes (a script
  through the `elixir` tool, a prompt to the agent, a reading of Visor's
  state) and the verdicts on them.

  A check is `{name, what, fun}`: `fun` takes the phase's context and
  returns a verdict, `:pass`, `{:fail, why}` or `{:skip, why}`. The steps
  it took go to the phase's sink, for the report.
  """

  alias Visor.Example.Recorder
  alias Visor.Harness

  @example "examples/todo_app"
  # A 16x16 red PNG.
  @red_png "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII="
  # What the offline copy's .env holds: no script may ever see it.
  @decoy "not-a-real-secret-7f3a"

  @type verdict :: :pass | {:fail, String.t()} | {:skip, String.t()}
  @type check :: {String.t(), String.t(), (map() -> verdict())}

  @doc "The picture the checks send and look at, as its bytes."
  def red_png, do: Base.decode64!(@red_png)

  @doc "What the offline copy's `.env` holds."
  def decoy, do: @decoy

  ## Phases

  @doc """
  Runs `checks` on a fresh copy of the example, in a session of its own,
  and returns one result for each, and one more when the session doesn't
  stop. `progress` gets the phase's results so far after each check, so a
  run stopped by hand still leaves what it found.
  """
  @spec phase(map(), :offline | :loop | :live, [check()], ([map()] -> any())) :: [map()]
  def phase(run, phase, checks, progress \\ fn _results -> :ok end) do
    ctx = start(run, phase)
    say("\n#{phase} (#{length(checks)} checks, session #{ctx.session}, in #{ctx.dir})")

    results =
      checks
      |> Enum.with_index(1)
      |> Enum.reduce([], fn {check, n}, done ->
        done = [run_check(ctx, n, check) | done]
        progress.(Enum.reverse(done))
        done
      end)
      |> Enum.reverse()

    case stop(ctx, length(checks) + 1) do
      [] ->
        results

      failed ->
        progress.(results ++ failed)
        results ++ failed
    end
  end

  @doc "A result for a phase that didn't run, and why."
  def skipped(phase, why) do
    say("\n#{phase}: skipped. #{why}")

    %{
      phase: phase,
      n: 1,
      name: "#{phase} checks",
      what: why,
      verdict: {:skip, why},
      ms: 0,
      steps: []
    }
  end

  defp start(run, phase) do
    dir = Path.join(run.copies, to_string(phase))
    File.mkdir_p!(run.copies)
    File.cp_r!(Path.join(run.root, @example), dir)
    for junk <- ["_build", "deps", ".visor", ".env"], do: File.rm_rf!(Path.join(dir, junk))
    File.write!(Path.join(dir, "red.png"), red_png())
    # Something for the workspace to refuse.
    if phase == :offline, do: File.write!(Path.join(dir, ".env"), "EXAMPLE_SECRET=#{@decoy}\n")

    Application.put_env(:visor, :workspace, dir)
    {:ok, id} = Harness.start_session(self(), label: "example #{phase}")
    :ok = Visor.Agent.subscribe(id)
    Recorder.watch(run.recorder, id, to_string(phase))

    {:ok, _settings} =
      case phase do
        # No model call offline: jobs that end don't wake the agent.
        :offline ->
          Visor.Agent.configure(id, jobs_wake: false)

        # The scripted model's calls: jobs wake the agent, as they do live.
        :loop ->
          Visor.Agent.configure(id, jobs_wake: true)

        :live ->
          Visor.Agent.configure(id,
            budget: {:prompt, run.budget},
            budget: {:session, run.budget * 8}
          )
      end

    {:ok, sink} = Agent.start_link(fn -> %{steps: [], reasons: []} end)
    Recorder.note(run.recorder, "phase_start", %{phase: phase, session: id, dir: dir})
    %{run: run, phase: phase, dir: dir, session: id, agent: agent_pid(id), sink: sink}
  end

  # The agent stops normally, and its session with it, jobs and all. One
  # that doesn't is a failed check of its own (the `n`th), in the log and
  # the report, not a run that goes on as if it had.
  defp stop(ctx, n) do
    Recorder.note(ctx.run.recorder, "phase_end", %{phase: ctx.phase, session: ctx.session})
    started = now()
    stopped = stop_agent(ctx.session)
    Agent.stop(ctx.sink)
    drain()

    case stopped do
      :ok ->
        []

      {:error, why} ->
        Recorder.note(ctx.run.recorder, "phase_stop_failed", %{
          phase: ctx.phase,
          session: ctx.session,
          why: why
        })

        say("  #{mark({:fail, why})} #{n}. the session stops: #{why}")

        [
          %{
            phase: ctx.phase,
            n: n,
            name: "the session stops",
            what: "The phase's agent stops normally within 10 s, and its session with it.",
            verdict: {:fail, why},
            ms: now() - started,
            steps: []
          }
        ]
    end
  end

  defp stop_agent(id) do
    case agent_pid(id) do
      nil -> :ok
      agent -> GenServer.stop(agent, :normal, 10_000)
    end
  catch
    # It ended on its own in between.
    :exit, :noproc -> :ok
    :exit, reason -> {:error, "its agent didn't stop: #{Exception.format_exit(reason)}"}
  end

  defp run_check(ctx, n, {name, what, fun}) do
    Recorder.note(ctx.run.recorder, "check_start", %{phase: ctx.phase, n: n, name: name})
    drain()
    started = now()

    verdict =
      try do
        normalize(fun.(ctx))
      rescue
        error -> {:fail, "the check raised: " <> Exception.format(:error, error, __STACKTRACE__)}
      catch
        kind, reason -> {:fail, "the check exited: #{inspect({kind, reason})}"}
      end

    steps = Agent.get_and_update(ctx.sink, &{Enum.reverse(&1.steps), %{&1 | steps: []}})

    result = %{
      phase: ctx.phase,
      n: n,
      name: name,
      what: what,
      verdict: verdict,
      ms: now() - started,
      steps: steps
    }

    Recorder.note(ctx.run.recorder, "check_end", %{
      phase: ctx.phase,
      n: n,
      name: name,
      verdict: verdict_text(verdict),
      ms: result.ms
    })

    say("  #{mark(verdict)} #{n}. #{name} (#{duration(result.ms)})#{why(verdict)}")
    result
  end

  ## Steps

  @doc """
  One script through the `elixir` tool, as the model's tool call would
  run: in a task of the session's, so a script whose process crashes
  fails its check, not the run. `raw:` gives the arguments as they are,
  `dune:` a prompt's variables (the step's `dune` has them after).
  """
  def script(ctx, code, opts \\ []) do
    arguments = Keyword.get(opts, :raw) || Jason.encode!(%{code: code})
    context = %{session: ctx.session, call_id: "x#{System.unique_integer([:positive])}"}
    drain()
    started = now()

    task =
      Task.Supervisor.async_nolink(Harness.via({ctx.session, :tasks}), fn ->
        case Keyword.get(opts, :dune) do
          nil ->
            {status, text, _facts} = Visor.Tools.execute("elixir", arguments, context)
            {status, text, nil}

          dune ->
            {status, text, _facts, dune} =
              Visor.Tools.execute("elixir", arguments, context, dune)

            {status, text, dune}
        end
      end)

    {status, text, dune} =
      case Task.yield(task, 300_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        {:exit, reason} ->
          {:crashed, "its process crashed: #{Exception.format_exit(reason)}", nil}

        nil ->
          {:timeout, "it was still running after 5 min", nil}
      end

    step = %{
      kind: :script,
      input: Keyword.get(opts, :raw) || code,
      status: status,
      output: text,
      ms: now() - started,
      events: drain()
    }

    push(ctx, step)
    Map.put(step, :dune, dune)
  end

  @doc """
  A prompt to the agent, and its events until it has been quiet for
  `settle:` ms (3,000) after its end: a steer or a wake starts another.
  `steer:` is sent while the first tool call runs; `pictures:` go with
  the prompt. A line shows as each model call and script ends.
  """
  def prompt(ctx, text, opts \\ []) do
    await_idle(ctx)
    drain()
    started = now()
    pictures = Keyword.get(opts, :pictures, [])
    reply = Visor.Agent.prompt(ctx.session, text, pictures)

    wait = %{
      deadline: now() + ctx.run.timeout,
      settle: Keyword.get(opts, :settle, 3_000),
      steer: Keyword.get(opts, :steer)
    }

    {status, events} = await_quiet(ctx, wait, [], false)

    if status == :timeout do
      _ = Visor.Agent.interrupt(ctx.session)
      drain()
    end

    reasons = for {:prompt_end, %{reason: reason}} <- events, do: reason
    Agent.update(ctx.sink, &%{&1 | reasons: &1.reasons ++ reasons})

    step = %{
      kind: :prompt,
      input: text,
      status: if(status == :ok, do: reply, else: :timeout),
      output: events |> answers() |> Enum.join("\n\n---\n\n"),
      ms: now() - started,
      events: events,
      pictures: Enum.map(pictures, &elem(&1, 0)),
      totals: Enum.reduce(events, %Visor.Agent.Totals{}, &Visor.Agent.Totals.add(&2, &1))
    }

    push(ctx, step)
    step
  end

  @doc "What a check read of Visor's state, or a command it ran, as a step of its own."
  def record(ctx, kind, input, status, output),
    do:
      push(ctx, %{kind: kind, input: input, status: status, output: output, ms: nil, events: []})

  @doc """
  Runs a command of the runner's own in the phase's copy, the way the
  agent's commands run (`Visor.Tools.shell/2`), and records it as a step:
  the code the model wrote can't read the key or other secrets, and a
  hang ends at `:timeout`. Options: `:env`, `:timeout` (2 min),
  `:max_bytes` (200 KB) and `:label`, the step's name. Returns
  `{status, output}`, the status being the exit code or `:timeout`.
  """
  @spec command(map(), String.t(), keyword()) :: {non_neg_integer() | :timeout, String.t()}
  def command(ctx, cmd, opts \\ []) do
    # Tools.shell/2 runs in the workspace, which start/2 set to the copy.
    root = Visor.Workspace.root()

    if root != ctx.dir,
      do: raise(ArgumentError, "the workspace is #{root}, not the phase's copy #{ctx.dir}")

    started = now()

    {status, output} =
      Visor.Tools.shell(cmd,
        env: Keyword.get(opts, :env, []),
        timeout: Keyword.get(opts, :timeout, 120_000),
        max_bytes: Keyword.get(opts, :max_bytes, 200_000)
      )

    push(ctx, %{
      kind: :command,
      input: Keyword.get(opts, :label, cmd),
      status: status,
      output: output,
      ms: now() - started,
      events: []
    })

    {status, output}
  end

  @doc """
  Session `id`'s lines in the run's `events.jsonl`, decoded, once the
  recorder has written what came before.
  """
  def recorded(ctx, id) do
    Recorder.sync(ctx.run.recorder)

    Path.join(ctx.run.out, "events.jsonl")
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["session"] == id))
  end

  @doc """
  The phase session's events until one matches, within `ms`:
  `{:ok, event, events}` or `{:timeout, events}`, the events in order.
  """
  def wait_for(match?, ms) do
    deadline = now() + ms
    wait_for(match?, deadline, [])
  end

  defp wait_for(match?, deadline, acc) do
    receive do
      {:agent, event} ->
        progress(event)

        if match?.(event),
          do: {:ok, event, Enum.reverse([event | acc])},
          else: wait_for(match?, deadline, [event | acc])
    after
      max(deadline - now(), 0) -> {:timeout, Enum.reverse(acc)}
    end
  end

  @doc "How each live prompt of the phase so far ended."
  def reasons(ctx), do: Agent.get(ctx.sink, & &1.reasons)

  defp push(ctx, step), do: Agent.update(ctx.sink, &%{&1 | steps: [step | &1.steps]})

  defp await_quiet(ctx, wait, acc, ended?) do
    left = max(wait.deadline - now(), 0)
    timeout = if ended?, do: min(wait.settle, left), else: left

    receive do
      {:agent, event} ->
        progress(event)
        wait = steer(ctx, wait, event)

        ended? =
          case event do
            {:prompt_end, _info} -> true
            {kind, _info} when kind in [:user, :wake, :turn_start] -> false
            _other -> ended?
          end

        await_quiet(ctx, wait, [event | acc], ended?)
    after
      timeout -> {if(ended?, do: :ok, else: :timeout), Enum.reverse(acc)}
    end
  end

  # A wake still running (a job that ended woke the agent) would take the
  # prompt as a steering message, and its events would count as the
  # prompt's: the prompt waits for the agent to be idle first, and the
  # wait, when there is one, is a step of its own. One that outlasts the
  # run's timeout is interrupted.
  defp await_idle(ctx) do
    leftover = drain()

    if idle?(ctx) do
      :ok
    else
      started = now()

      {status, events} =
        case wait_idle(ctx, now() + ctx.run.timeout, Enum.reverse(leftover)) do
          {:timeout, events} ->
            _ = Visor.Agent.interrupt(ctx.session)
            {_status, events} = wait_idle(ctx, now() + 10_000, Enum.reverse(events))
            {:timeout, events}

          done ->
            done
        end

      ms = now() - started
      wakes = Enum.count(events, &match?({:wake, _text}, &1))

      output =
        if status == :ok,
          do: "It was busy (#{wakes} wakes), so the prompt waited #{duration(ms)} for it.",
          else: "It was still busy after #{duration(ms)}, so it was interrupted."

      push(ctx, %{
        kind: :wait,
        input: "the agent busy as the prompt came",
        status: status,
        output: output,
        ms: ms,
        events: events
      })
    end
  end

  defp idle?(ctx), do: Visor.Agent.settings(ctx.session).status == :idle

  # Until it says it is idle and is: a status event may be older than the
  # one it is in now. `acc` is newest first.
  defp wait_idle(ctx, deadline, acc) do
    receive do
      {:agent, event} ->
        progress(event)
        acc = [event | acc]

        if event == {:status, :idle} and idle?(ctx),
          do: {:ok, Enum.reverse(acc)},
          else: wait_idle(ctx, deadline, acc)
    after
      max(deadline - now(), 0) -> {:timeout, Enum.reverse(acc)}
    end
  end

  defp steer(ctx, %{steer: text} = wait, {:tool_start, _call}) when is_binary(text) do
    _ = Visor.Agent.prompt(ctx.session, text)
    %{wait | steer: nil}
  end

  defp steer(_ctx, wait, _event), do: wait

  # A long prompt shows that it moves.
  defp progress({:turn_end, %{turn: turn, finish_reason: reason} = info}),
    do: say("      · model call #{turn}: #{reason} (#{duration(info[:ms])})")

  defp progress({:tool_end, %{status: status} = call}),
    do: say("      · script #{status} (#{duration(call[:ms])})")

  defp progress({:steer, _text}), do: say("      · the steering message went in")
  defp progress({:wake, _text}), do: say("      · woke on its own")
  defp progress({:job_end, job}), do: say("      · job #{job.id} ended: #{job.status}")
  defp progress(_event), do: :ok

  ## Verdicts

  @doc "The step ended `status`, and its result holds each pattern."
  def expect(step, status, patterns) do
    cond do
      step.status != status ->
        {:fail,
         "it ended #{inspect(step.status)}, not #{inspect(status)}: #{excerpt(step.output)}"}

      missing = Enum.find(patterns, &(not (step.output =~ &1))) ->
        {:fail, "its result lacks #{inspect(missing)}: #{excerpt(step.output)}"}

      true ->
        :pass
    end
  end

  @doc "The step's result doesn't show `text`."
  def refute_output(step, text) do
    if step.output =~ text, do: {:fail, "its result shows #{inspect(text)}"}, else: :pass
  end

  @doc "One of the step's events matches."
  def event(step, what, match?) do
    if Enum.any?(step.events, match?),
      do: :pass,
      else: {:fail, "no #{what} among its #{length(step.events)} events"}
  end

  @doc """
  An event that comes from another process after the step returned: one
  of the check's steps had it, or it comes within 5 s.
  """
  def await_event(ctx, what, match?) do
    seen = Agent.get(ctx.sink, &Enum.flat_map(&1.steps, fn step -> step.events end))
    if Enum.any?(seen, match?), do: :pass, else: await_later(what, match?, now() + 5_000)
  end

  defp await_later(what, match?, deadline) do
    receive do
      {:agent, event} ->
        if match?.(event), do: :pass, else: await_later(what, match?, deadline)
    after
      max(deadline - now(), 0) -> {:fail, "no #{what} within 5 s"}
    end
  end

  @doc "The prompt ended, each time, for one of `reasons`."
  def ended(step, reasons) do
    ends = for {:prompt_end, info} <- step.events, do: info.reason

    cond do
      step.status == :timeout -> {:fail, "it was still running after its time"}
      ends == [] -> {:fail, "it never ended"}
      Enum.all?(ends, &(&1 in reasons)) -> :pass
      true -> {:fail, "it ended with #{inspect(ends)}"}
    end
  end

  @doc "What the model said matches `pattern`."
  def answered(step, pattern) do
    if step.output =~ pattern,
      do: :pass,
      else: {:fail, "its answer doesn't match #{inspect(pattern)}: #{excerpt(step.output)}"}
  end

  @doc "The first verdict that isn't a pass, or a pass."
  def all(verdicts), do: Enum.find(verdicts, :pass, &(&1 != :pass))

  @doc "A verdict for `ok?`."
  def pass_if(true, _why), do: :pass
  def pass_if(_false, why), do: {:fail, why}

  defp normalize(:pass), do: :pass
  defp normalize({:fail, why}) when is_binary(why), do: {:fail, why}
  defp normalize({:skip, why}), do: {:skip, why}
  defp normalize(other), do: {:fail, "the check returned #{inspect(other)}"}

  ## Reading the run

  @doc "The job id a script's result names."
  def job_id(step), do: with([_, id] <- Regex.run(~r/job: "(j\d+)"/, step.output), do: id)

  @doc "A file of the phase's copy, as its SHA-256."
  def digest(ctx, path),
    do: :crypto.hash(:sha256, File.read!(Path.join(ctx.dir, path))) |> Base.encode16()

  @doc "How many of the conversation's messages hold a picture."
  def conversation_pictures(ctx) do
    ctx.session
    |> Visor.Agent.messages()
    |> Enum.count(&(Visor.Content.images(&1["content"]) > 0))
  end

  @doc "The agent's pid now."
  def agent_pid(id), do: GenServer.whereis(Harness.via({id, :agent}))

  @doc "The model's text: each model call's that had any."
  def answers(events) do
    for {:turn_end, %{final: %{content: content}}} <- events,
        is_binary(content) and String.trim(content) != "",
        do: String.trim(content)
  end

  defp drain(acc \\ []) do
    receive do
      {:agent, event} -> drain([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  ## Text

  def mark(:pass), do: "✓"
  def mark({:fail, _why}), do: "✗"
  def mark({:skip, _why}), do: "–"

  def verdict_text(:pass), do: "pass"
  def verdict_text({:fail, _why}), do: "FAIL"
  def verdict_text({:skip, _why}), do: "skipped"

  defp why({:fail, why}), do: "\n      " <> excerpt(why, 300)
  defp why(_verdict), do: ""

  def excerpt(text, max \\ 400)
  def excerpt(nil, _max), do: ""

  def excerpt(text, max) when is_binary(text) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> " …", else: text
  end

  def excerpt(other, max), do: other |> inspect() |> excerpt(max)

  def duration(nil), do: "–"
  def duration(ms) when ms < 1_000, do: "#{ms} ms"
  def duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)} s"
  def duration(ms), do: "#{div(ms, 60_000)} min #{rem(div(ms, 1000), 60)} s"

  def say(text), do: Mix.shell().info(text)

  defp now, do: System.monotonic_time(:millisecond)
end
