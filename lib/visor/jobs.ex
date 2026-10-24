defmodule Visor.Jobs do
  @moduledoc """
  A session's background jobs: work a script starts and doesn't wait
  for, such as `V.sh("mix test", background: true)`. The script gets the
  job's id at once; the job runs on, and when it ends the agent hears of
  it (see `Visor.Agent`), so the model doesn't have to poll.

  Each job runs in a task under the session's job supervisor, which is
  the task that owns its command: when the job is stopped or the session
  ends, the task exits, and the shell's watchdog kills the command and
  what it started (see `Visor.Tools.shell/2`).

  A job's record lives in the session's table, under `{:job, id}`, so an
  agent or jobs server crash loses none of them, and reads don't call
  this server. The task writes its own end into the record before it
  tells the server, so a restarted server still sees it. Its output goes
  to a private file, and the record keeps its last
  `Visor.Limits.job_tail_bytes/0`.

  The server hands out ids, answers `wait/3`, stops jobs, and tells the
  agent and the console when a job ends.
  """
  use GenServer

  alias Visor.{Format, Harness, Limits, Tools}
  alias Visor.Agent.Event
  alias Visor.Harness.Session

  @typedoc "A job as the session's table keeps it."
  @type job :: %{
          id: String.t(),
          kind: :shell,
          label: String.t(),
          status: :running | :exited | :failed | :killed | :timed_out,
          exit: integer() | nil,
          started: integer(),
          ms: non_neg_integer() | nil,
          timeout_ms: pos_integer(),
          log: String.t(),
          tail: String.t(),
          os_pid: integer() | nil,
          pid: pid() | nil,
          acknowledged: boolean()
        }

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: Harness.via({id, :jobs}))
  end

  @doc "Starts `command` as a job of session `session`. Returns `{:ok, job}`."
  def start_shell(session, command, timeout_ms, wake_on \\ nil) do
    GenServer.call(Harness.via({session, :jobs}), {:start, :shell, command, timeout_ms, wake_on})
  end

  @doc """
  Starts a timer (see `V.schedule/2`): a job that ends after `ms` with
  `note` as its output, whose notice wakes the agent as any job's does,
  after Jido's scheduled signals. Returns `{:ok, job}` or `{:error, message}`.
  """
  def start_timer(session, ms, note) do
    GenServer.call(Harness.via({session, :jobs}), {:start, :timer, ms, note})
  end

  @doc """
  Starts a sub-agent as a job of session `session` (see `V.agent/2`): a
  session of its own, owned by the job's task, given `prompt` as its
  first message. `opts` has its `:task` (the label), `:max_steps`,
  `:role` and `:timeout_ms`. Returns `{:ok, job}` or `{:error, message}`.
  """
  def start_agent(session, prompt, opts) do
    GenServer.call(Harness.via({session, :jobs}), {:start, :agent, prompt, opts})
  end

  @doc """
  Starts a council (see `V.council/2`): a sub-agent per role on `task`,
  at once, then with `synthesize` one more that weighs their answers.
  The members are jobs of their own, marked as the council's, and the
  agent hears only of the council. Returns `{:ok, job}` or
  `{:error, message}`.
  """
  def start_council(session, task, opts) do
    GenServer.call(Harness.via({session, :jobs}), {:start, :council, task, opts})
  end

  @doc "Session `session`'s job `id`, or nil."
  def get(session, id) do
    with store when store != nil <- Session.store(session),
         [{_key, job}] <- :ets.lookup(store, {:job, id}) do
      job
    else
      _ -> nil
    end
  end

  @doc "Session `session`'s jobs, oldest first."
  def list(session) do
    case Session.store(session) do
      nil -> []
      store -> store |> :ets.match_object({{:job, :_}, :_}) |> Enum.map(&elem(&1, 1)) |> sort()
    end
  end

  @doc "The jobs still running."
  def running(session), do: Enum.filter(list(session), &(&1.status == :running))

  @doc "Stops job `id`. Returns `{:ok, job}` or `{:error, message}`."
  def stop(session, id), do: GenServer.call(Harness.via({session, :jobs}), {:stop, id})

  @doc """
  Waits up to `timeout_ms` for job `id` to end, and returns it as it is
  then: `{:ok, job}` or `{:error, message}`.
  """
  def wait(session, id, timeout_ms) do
    GenServer.call(Harness.via({session, :jobs}), {:wait, id, timeout_ms}, timeout_ms + 5_000)
  end

  @doc """
  Marks job `id` as seen by the model, so the agent doesn't tell it again
  that it ended.
  """
  def acknowledge(session, id) do
    with %{status: status} = job when status != :running <- get(session, id) do
      put(session, %{job | acknowledged: true})
    end

    :ok
  end

  @doc "The job as events, the console and `V.job/1` show it."
  def public(job), do: Map.drop(job, [:pid, :started, :announced])

  @doc "What the model is told when job `job` has ended."
  def notice(%{kind: :council} = job) do
    answer = String.trim(job.tail || "")
    members = length(Map.get(job, :members, []))

    how =
      case {job.status, answer} do
        {:exited, answer} -> "answered (#{shorten(answer, 300)})"
        {status, ""} -> "#{status}"
        {status, why} -> "#{status} (#{shorten(why, 300)})"
      end

    "[Visor: council #{job.id} (#{label(job)}) of #{members} sub-agents #{how} " <>
      "after #{Format.duration(job.ms)}. " <> ~s|V.output("#{job.id}") has its whole answer.]|
  end

  def notice(%{kind: :agent} = job) do
    answer = String.trim(job.tail || "")

    how =
      case {job.status, answer} do
        {:exited, ""} -> "ended without an answer"
        {:exited, answer} -> "answered (#{shorten(answer, 300)})"
        {:timed_out, _} -> "was stopped at its #{Format.duration(job.timeout_ms)} time limit"
        {:killed, _} -> "was stopped"
        {_failed, _} -> "failed (#{Map.get(job, :reason, :error)})"
      end

    "[Visor: sub-agent #{job.id} (#{label(job)}) #{how} after #{Format.duration(job.ms)}. " <>
      ~s|V.output("#{job.id}") has its whole answer.]|
  end

  def notice(%{kind: :timer} = job) do
    how = if job.status == :exited, do: "went off", else: "#{job.status}"
    "[Visor: timer #{job.id} (#{label(job)}) #{how} after #{Format.duration(job.ms)}.]"
  end

  def notice(job) do
    how =
      case job.status do
        :exited -> "exited with status 0"
        :failed when is_integer(job.exit) -> "failed with status #{job.exit}"
        :failed -> "failed"
        :timed_out -> "was stopped at its #{Format.duration(job.timeout_ms)} time limit"
        :killed -> "was stopped"
      end

    "[Visor: background job #{job.id} (#{label(job)}) #{how} after #{Format.duration(job.ms)}. " <>
      ~s|V.job("#{job.id}") shows the end of its output; V.output("#{job.id}") the whole of it.]|
  end

  defp shorten(text, chars) do
    if String.length(text) > chars, do: String.slice(text, 0, chars) <> "…", else: text
  end

  @doc "A job's command, cut to one short line."
  def label(job) do
    line = job.label |> String.split("\n", parts: 2) |> hd()
    if String.length(line) > 60, do: String.slice(line, 0, 60) <> "…", else: line
  end

  ## Server

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    Process.set_label("jobs #{id}")
    Process.flag(:trap_exit, true)

    # After a restart: watch the jobs still running, and keep numbering
    # after the last.
    jobs = list(id)

    monitors =
      for %{status: :running, pid: pid} = job <- jobs, is_pid(pid), into: %{} do
        {Process.monitor(pid), job.id}
      end

    {:ok,
     %{
       id: id,
       tasks: Keyword.fetch!(opts, :tasks),
       next: length(jobs) + 1,
       monitors: monitors,
       waiters: %{}
     }}
  end

  @impl true
  def handle_call({:start, :agent, prompt, opts}, from, state) do
    agents = Enum.count(running(state.id), &(&1.kind == :agent))

    cond do
      Session.depth(state.id) >= Limits.agent_depth() ->
        {:reply,
         {:error,
          "A sub-agent can't start sub-agents of its own (at most " <>
            "#{Limits.agent_depth()} level). Do the work yourself."}, state}

      agents >= Limits.agents_at_once() ->
        {:reply,
         {:error,
          "#{Limits.agents_at_once()} sub-agents are running already, the most a session may " <>
            "run. Wait for one to end."}, state}

      true ->
        start(state, from, :agent, opts.task, opts.timeout_ms, fn session, job ->
          run_agent(session, job, prompt, opts)
        end)
        |> mark_member(state.id, opts[:council])
    end
  end

  def handle_call({:start, :council, task, opts}, from, state) do
    cond do
      Session.depth(state.id) >= Limits.agent_depth() ->
        {:reply, {:error, "A sub-agent can't start a council."}, state}

      length(opts.roles) > Limits.agents_at_once() ->
        {:reply,
         {:error,
          "A council has at most #{Limits.agents_at_once()} roles, the sub-agents a session " <>
            "may run at once."}, state}

      Enum.any?(running(state.id), &(&1.kind == :agent)) ->
        {:reply, {:error, "Wait for the running sub-agents to end before a council."}, state}

      true ->
        start(state, from, :council, task, opts.timeout_ms, fn session, job ->
          run_council(session, job, task, opts)
        end)
    end
  end

  def handle_call({:start, :shell, command, timeout_ms, wake_on}, from, state) do
    start(
      state,
      from,
      :shell,
      command,
      timeout_ms,
      &run_shell(&1, Map.put(&2, :wake_on, wake_on))
    )
  end

  def handle_call({:start, :timer, ms, note}, from, state) do
    # The timer goes off before its job's own time limit would stop it.
    start(state, from, :timer, note, ms + 60_000, fn session, job ->
      run_timer(session, job, ms)
    end)
  end

  def handle_call({:stop, job_id}, _from, state), do: stop_job(state, job_id)

  def handle_call({:wait, job_id, timeout_ms}, from, state),
    do: wait_job(state, job_id, timeout_ms, from)

  defp start(state, _from, kind, label, timeout_ms, run) do
    held = Visor.Alarms.held()

    if held || length(running(state.id)) >= Limits.jobs_at_once() do
      message =
        held ||
          "#{Limits.jobs_at_once()} jobs are running already, the most a session may run. " <>
            "Wait for one to end, or stop one with V.stop(id)."

      {:reply, {:error, message}, state}
    else
      start_job(state, kind, label, timeout_ms, run)
    end
  end

  defp start_job(state, kind, label, timeout_ms, run) do
    job_id = "j#{state.next}"
    log = log_path(state.id, job_id)

    job = %{
      id: job_id,
      kind: kind,
      label: label,
      status: :running,
      exit: nil,
      started: now(),
      ms: nil,
      timeout_ms: timeout_ms,
      log: log,
      tail: "",
      os_pid: nil,
      pid: nil,
      acknowledged: false
    }

    session = state.id

    {:ok, pid} =
      Task.Supervisor.start_child(state.tasks, fn -> run.(session, job) end, restart: :temporary)

    job = %{job | pid: pid}
    put(session, job)
    ref = Process.monitor(pid)
    # A sub-agent's job says it started once its child session has.
    if kind != :agent, do: Event.broadcast(session, {:job_start, public(job)})

    {:reply, {:ok, job},
     %{state | next: state.next + 1, monitors: Map.put(state.monitors, ref, job_id)}}
  end

  # A council's member is marked as its, so the agent hears of the
  # council alone.
  defp mark_member({:reply, {:ok, job}, state}, session, council) when is_binary(council) do
    job = Map.put(job, :council, council)
    put(session, job)
    {:reply, {:ok, job}, state}
  end

  defp mark_member(reply, _session, _council), do: reply

  defp stop_job(state, job_id) do
    case get(state.id, job_id) do
      nil ->
        {:reply, {:error, "There is no job #{job_id}."}, state}

      %{status: :running, pid: pid} = job ->
        # Marked first, so the exit that follows reads as stopped.
        put(state.id, %{job | status: :killed, ms: now() - job.started})

        cond do
          not is_pid(pid) ->
            :ok

          # A council's members go with it.
          job.kind == :council ->
            for %{council: ^job_id, status: :running} = member <- list(state.id),
                do: stop_job(state, member.id)

            Process.exit(pid, :kill)

          # A sub-agent's task counts what its child did so far before it
          # goes; it is killed if it hasn't within a second.
          job.kind == :agent ->
            send(pid, :stop)
            Process.send_after(self(), {:kill, pid}, 1_000)

          true ->
            Process.exit(pid, :kill)
        end

        {:reply, {:ok, get(state.id, job_id)}, state}

      job ->
        {:reply, {:ok, job}, state}
    end
  end

  defp wait_job(state, job_id, timeout_ms, from) do
    case get(state.id, job_id) do
      nil ->
        {:reply, {:error, "There is no job #{job_id}."}, state}

      %{status: :running} ->
        timer = Process.send_after(self(), {:waited, job_id, from}, timeout_ms)
        waiters = Map.update(state.waiters, job_id, [{from, timer}], &[{from, timer} | &1])
        {:noreply, %{state | waiters: waiters}}

      job ->
        {:reply, {:ok, job}, state}
    end
  end

  @impl true
  def handle_cast({:ended, job_id}, state), do: {:noreply, ended(state, job_id)}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when is_map_key(state.monitors, ref) do
    {job_id, monitors} = Map.pop(state.monitors, ref)
    state = %{state | monitors: monitors}

    # A task that ended normally has written its end already; one that
    # was killed or crashed hasn't.
    case get(state.id, job_id) do
      %{status: :running} = job ->
        put(state.id, %{job | status: :failed, ms: now() - job.started})
        {:noreply, ended(state, job_id)}

      %{status: :killed} ->
        {:noreply, ended(state, job_id)}

      _ended ->
        {:noreply, state}
    end
  end

  def handle_info({:waited, job_id, from}, state) do
    GenServer.reply(from, {:ok, get(state.id, job_id)})

    waiters =
      Map.update(state.waiters, job_id, [], fn list ->
        Enum.reject(list, fn {waiter, _timer} -> waiter == from end)
      end)

    {:noreply, %{state | waiters: waiters}}
  end

  def handle_info({:kill, pid}, state) do
    Process.exit(pid, :kill)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The session is ending: its jobs' tasks are stopped with it, which
  # kills their commands. Their files go too.
  @impl true
  def terminate(_reason, state) do
    File.rm_rf(Path.dirname(log_path(state.id, "j0")))
    :ok
  end

  # Tells whoever waits for the job, the console and the agent, once.
  defp ended(state, job_id) do
    job = get(state.id, job_id)

    if job && not Map.get(job, :announced, false) do
      put(state.id, Map.put(job, :announced, true))

      for {from, timer} <- Map.get(state.waiters, job_id, []) do
        Process.cancel_timer(timer)
        GenServer.reply(from, {:ok, job})
      end

      Event.broadcast(state.id, {:job_end, public(job)})
      # A council's member is the council's to hear of.
      unless Map.get(job, :council), do: Visor.Agent.job_ended(state.id, job_id)
      %{state | waiters: Map.delete(state.waiters, job_id)}
    else
      state
    end
  end

  ## The job's task

  defp run_shell(session, job) do
    Process.set_label("job #{job.id}")
    File.mkdir_p!(Path.dirname(job.log))
    File.chmod!(Path.dirname(job.log), 0o700)
    {:ok, file} = File.open(job.log, [:write, :binary])
    File.chmod!(job.log, 0o600)
    Process.put(:job_tail, "")
    Process.put(:job_flushed, now())
    Process.put(:job_logged, 0)
    max = Limits.job_log_bytes()

    Process.put(:job_watching, Map.get(job, :wake_on))

    on_data = fn data ->
      # The file stops at its limit, once saying so; the tail goes on.
      case Process.get(:job_logged) do
        logged when logged + byte_size(data) <= max ->
          IO.binwrite(file, data)
          Process.put(:job_logged, logged + byte_size(data))

        logged when logged <= max ->
          IO.binwrite(file, [
            binary_part(data, 0, max - logged),
            "\n[Visor: the log stops here, at #{Format.number(max)} bytes. The job goes on; " <>
              "the end of its output is in V.job(\"#{job.id}\").]\n"
          ])

          Process.put(:job_logged, max + 1)

        _past_the_limit ->
          :ok
      end

      tail = keep_tail(Process.get(:job_tail) <> data)
      Process.put(:job_tail, tail)
      watch(session, job, tail)

      # The record's tail follows, a few times a second at most.
      if now() - Process.get(:job_flushed) >= 250 do
        update(session, job.id, &%{&1 | tail: tail})
        Process.put(:job_flushed, now())
      end
    end

    on_start = fn os_pid -> update(session, job.id, &%{&1 | os_pid: os_pid}) end

    {status, _output} =
      Tools.shell(job.label,
        timeout: job.timeout_ms,
        max_bytes: 0,
        on_start: on_start,
        on_data: on_data
      )

    File.close(file)

    update(session, job.id, fn record ->
      %{
        record
        | status: status(status),
          exit: if(is_integer(status), do: status),
          ms: now() - record.started,
          tail: Process.get(:job_tail)
      }
    end)

    GenServer.cast(Harness.via({session, :jobs}), {:ended, job.id})
  end

  # The first line of a job's output that matches its wake_on, after
  # Jido's sensors: the agent hears of it while the job runs on.
  defp watch(session, job, tail) do
    with pattern when pattern != nil <- Process.get(:job_watching),
         line when is_binary(line) <- matching_line(tail, pattern) do
      Process.put(:job_watching, nil)
      update(session, job.id, &Map.put(&1, :matched, line))

      Visor.Agent.job_notice(
        session,
        "[Visor: background job #{job.id} (#{label(job)}) printed a line matching " <>
          "#{inspect(pattern_text(pattern))}: #{String.slice(line, 0, 300)}. It is still " <>
          "running; V.job(\"#{job.id}\") shows the end of its output.]"
      )
    end
  end

  defp matching_line(tail, pattern) do
    tail
    |> String.split("\n")
    |> Enum.find(fn line ->
      if is_binary(pattern),
        do: String.contains?(line, pattern),
        else: Regex.match?(pattern, line)
    end)
  end

  defp pattern_text(%Regex{source: source}), do: "~r/" <> source <> "/"
  defp pattern_text(text), do: text

  defp run_timer(session, job, ms) do
    Process.set_label("job #{job.id}")
    Process.sleep(ms)
    File.mkdir_p!(Path.dirname(job.log))
    File.write!(job.log, job.label)
    File.chmod!(job.log, 0o600)

    update(session, job.id, fn record ->
      Map.merge(record, %{status: :exited, exit: 0, ms: now() - record.started, tail: job.label})
    end)

    GenServer.cast(Harness.via({session, :jobs}), {:ended, job.id})
  end

  # A sub-agent: a session of its own whose owner is this task, so it
  # ends when the job is stopped or its parent's session ends. The job
  # ends with the child's first prompt, and its output is the child's
  # last answer.
  defp run_agent(session, job, prompt, opts) do
    Process.set_label("job #{job.id}")

    {:ok, child} =
      Harness.start_session(self(),
        depth: Session.depth(session) + 1,
        max_steps: opts.max_steps,
        role: opts.role,
        read_only: Map.get(opts, :read_only, false),
        limits: Map.get(opts, :limits),
        label: "agent #{job.id} of #{session}",
        parent: "#{session}/#{job.id}"
      )

    update(session, job.id, &Map.put(&1, :child, child))
    Event.broadcast(session, {:job_start, public(get(session, job.id))})
    Visor.Agent.subscribe(child)
    :ok = Visor.Agent.prompt(child, prompt)

    {reason, totals} =
      await_child({session, job.id}, job.started + job.timeout_ms, %Visor.Agent.Totals{})

    # What the child spent is its parent's spending too.
    Visor.Agent.spent(session, totals.cost, totals.prompt_tokens + totals.completion_tokens)

    answer = child_answer(child)

    File.mkdir_p!(Path.dirname(job.log))
    File.chmod!(Path.dirname(job.log), 0o700)
    File.write!(job.log, answer)
    File.chmod!(job.log, 0o600)

    update(session, job.id, fn record ->
      record
      |> Map.merge(%{
        status: agent_status(reason),
        ms: now() - record.started,
        tail: keep_tail(answer),
        totals: Visor.Agent.Totals.to_map(totals)
      })
      |> Map.put(:reason, reason)
    end)

    GenServer.cast(Harness.via({session, :jobs}), {:ended, job.id})
  end

  # Starts the members, waits for each, then has the answers that came
  # back weighed, after pi-fabric's council: one answer needs no
  # synthesis, and a member that failed has no views to weigh.
  defp run_council(session, job, task, opts) do
    Process.set_label("job #{job.id}")
    left = fn -> max(job.started + job.timeout_ms - now(), 0) end

    agent = fn prompt, role ->
      start_agent(session, prompt, Map.put(agent_opts(task, role, opts), :council, job.id))
    end

    started = for role <- Enum.uniq(opts.roles), do: {role, agent.(task, role)}
    ids = for {_role, {:ok, member}} <- started, do: member.id
    update(session, job.id, &Map.put(&1, :members, ids))

    answers =
      for {role, start} <- started do
        with {:ok, member} <- start,
             {:ok, %{status: :exited} = member} <- wait(session, member.id, left.()),
             answer when answer != "" <- String.trim(member_answer(member)) do
          {role, {:ok, answer}}
        else
          {:ok, %{status: :running}} -> {role, {:failed, "no answer in time"}}
          {:ok, member} -> {role, {:failed, to_string(member.status)}}
          {:error, message} -> {role, {:failed, message}}
          "" -> {role, {:failed, "no answer"}}
        end
      end

    answered = for {role, {:ok, answer}} <- answers, do: {role, answer}
    failed = for {role, {:failed, why}} <- answers, do: "#{role} (#{why})"
    joined = joined(answered, failed)

    {status, answer, ids} =
      cond do
        answered == [] ->
          {:failed, "No member of the council answered: #{Enum.join(failed, ", ")}.", ids}

        not opts.synthesize or length(answered) == 1 ->
          {:exited, joined, ids}

        true ->
          gone =
            if failed == [],
              do: "",
              else: " Don't guess at the views of #{Enum.join(failed, ", ")}."

          prompt =
            "Several reviewers answered this task on their own. Weigh their answers and give " <>
              "one decision: reject claims they don't support, keep the disagreements that " <>
              "matter, and say which role raised each concern.#{gone}\n\nTask: #{task}\n\n" <>
              joined

          with {:ok, synthesis} <- agent.(prompt, "the synthesizer of a council"),
               _ =
                 update(
                   session,
                   job.id,
                   &Map.update!(&1, :members, fn m -> m ++ [synthesis.id] end)
                 ),
               {:ok, %{status: :exited} = done} <- wait(session, synthesis.id, left.()) do
            {:exited, member_answer(done), ids ++ [synthesis.id]}
          else
            _no_synthesis ->
              {:exited, "The synthesis gave no answer; the members':\n\n" <> joined, ids}
          end
      end

    File.mkdir_p!(Path.dirname(job.log))
    File.write!(job.log, answer)
    File.chmod!(job.log, 0o600)

    update(session, job.id, fn record ->
      Map.merge(record, %{
        status: status,
        ms: now() - record.started,
        tail: keep_tail(answer),
        members: Map.get(record, :members, ids)
      })
    end)

    GenServer.cast(Harness.via({session, :jobs}), {:ended, job.id})
  end

  defp joined(answered, failed) do
    answers = Enum.map_join(answered, "\n\n", fn {role, answer} -> "## #{role}\n\n#{answer}" end)

    if failed == [],
      do: answers,
      else: answers <> "\n\nNo answer from: #{Enum.join(failed, ", ")}."
  end

  # Members and the synthesizer only read, as pi-fabric's council's do,
  # and share what the parent's prompt may still spend.
  defp agent_opts(task, role, opts) do
    shares = length(opts.roles) + 1

    %{
      task: task,
      role: role,
      max_steps: opts.max_steps,
      timeout_ms: opts.timeout_ms,
      read_only: true,
      limits: opts[:limits] && Map.new(opts.limits, fn {k, v} -> {k, share(v, shares)} end)
    }
  end

  defp share(n, shares) when is_integer(n), do: div(n, shares)
  defp share(n, shares), do: n / shares

  defp member_answer(%{log: log, tail: tail}) do
    case File.read(log) do
      {:ok, answer} -> answer
      {:error, _reason} -> tail || ""
    end
  end

  # The child's events, counted, until its first prompt ends. The count
  # goes into the record as each model call and tool call ends, so a
  # stopped child's spending is still counted.
  defp await_child({session, job_id} = job, deadline, totals) do
    receive do
      {:agent, {:prompt_end, %{reason: reason}} = event} ->
        {reason, Visor.Agent.Totals.add(totals, event)}

      {:agent, {kind, _info} = event} when kind in [:turn_end, :tool_end] ->
        totals = Visor.Agent.Totals.add(totals, event)
        update(session, job_id, &Map.put(&1, :totals, Visor.Agent.Totals.to_map(totals)))
        await_child(job, deadline, totals)

      {:agent, event} ->
        await_child(job, deadline, Visor.Agent.Totals.add(totals, event))

      :stop ->
        totals = drain(totals)
        update(session, job_id, &Map.put(&1, :totals, Visor.Agent.Totals.to_map(totals)))
        exit(:normal)
    after
      max(deadline - now(), 0) -> {:timeout, totals}
    end
  end

  # The child's events already here when the job was stopped.
  defp drain(totals) do
    receive do
      {:agent, event} -> drain(Visor.Agent.Totals.add(totals, event))
    after
      0 -> totals
    end
  end

  defp child_answer(child) do
    with store when store != nil <- Session.store(child),
         [{:conversation, %{messages: messages}}] <- :ets.lookup(store, :conversation),
         %{"content" => content} when is_binary(content) <-
           Enum.find(
             Enum.reverse(messages),
             &(&1["role"] == "assistant" and &1["content"] not in [nil, ""])
           ) do
      content
    else
      _ -> ""
    end
  end

  defp agent_status(reason) when reason in [:answered, :step_limit, :max_tokens], do: :exited
  defp agent_status(:timeout), do: :timed_out
  defp agent_status(_reason), do: :failed

  defp status(0), do: :exited
  defp status(:timeout), do: :timed_out
  defp status(_code), do: :failed

  defp keep_tail(text) do
    max = Limits.job_tail_bytes()

    if byte_size(text) > max do
      cut = binary_part(text, byte_size(text) - max, max)
      # Not from the middle of a UTF-8 character.
      case String.chunk(cut, :valid) do
        [first | rest] -> if String.valid?(first), do: cut, else: Enum.join(rest)
        [] -> cut
      end
    else
      text
    end
  end

  defp update(session, job_id, fun) do
    case get(session, job_id) do
      # A job stopped while its task finishes stays stopped, at the time
      # it was stopped.
      %{status: :killed} = job ->
        put(session, Map.merge(fun.(job), %{status: :killed, ms: job.ms}))

      nil ->
        :ok

      job ->
        put(session, fun.(job))
    end
  end

  defp put(session, job) do
    if store = Session.store(session), do: :ets.insert(store, {{:job, job.id}, job})
    :ok
  end

  defp sort(jobs) do
    Enum.sort_by(jobs, fn %{id: "j" <> n} -> String.to_integer(n) end)
  end

  defp log_path(session, job_id) do
    # Under this VM's OS pid, so two Visors never share or remove the
    # other's files.
    Path.join([
      System.tmp_dir!(),
      "visor-jobs",
      System.pid(),
      to_string(session),
      "#{job_id}.log"
    ])
  end

  defp now, do: System.monotonic_time(:millisecond)
end
