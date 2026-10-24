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
  def start_shell(session, command, timeout_ms) do
    GenServer.call(Harness.via({session, :jobs}), {:start, :shell, command, timeout_ms})
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
  def handle_call({:start, :shell, command, timeout_ms}, _from, state) do
    if length(running(state.id)) >= Limits.jobs_at_once() do
      {:reply,
       {:error,
        "#{Limits.jobs_at_once()} jobs are running already, the most a session may run. " <>
          "Wait for one to end, or stop one with V.stop(id)."}, state}
    else
      job_id = "j#{state.next}"
      log = log_path(state.id, job_id)

      job = %{
        id: job_id,
        kind: :shell,
        label: command,
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
        Task.Supervisor.start_child(state.tasks, fn -> run_shell(session, job) end,
          restart: :temporary
        )

      job = %{job | pid: pid}
      put(session, job)
      ref = Process.monitor(pid)
      Event.broadcast(session, {:job_start, public(job)})

      {:reply, {:ok, job},
       %{state | next: state.next + 1, monitors: Map.put(state.monitors, ref, job_id)}}
    end
  end

  def handle_call({:stop, job_id}, _from, state) do
    case get(state.id, job_id) do
      nil ->
        {:reply, {:error, "There is no job #{job_id}."}, state}

      %{status: :running, pid: pid} = job ->
        # Marked first, so the exit that follows reads as stopped.
        put(state.id, %{job | status: :killed, ms: now() - job.started})
        if is_pid(pid), do: Process.exit(pid, :kill)
        {:reply, {:ok, get(state.id, job_id)}, state}

      job ->
        {:reply, {:ok, job}, state}
    end
  end

  def handle_call({:wait, job_id, timeout_ms}, from, state) do
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
      Visor.Agent.job_ended(state.id, job_id)
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

    on_data = fn data ->
      IO.binwrite(file, data)
      tail = keep_tail(Process.get(:job_tail) <> data)
      Process.put(:job_tail, tail)

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
      # A job stopped while its task finishes stays stopped.
      %{status: :killed} = job -> put(session, %{job | tail: Process.get(:job_tail) || job.tail})
      nil -> :ok
      job -> put(session, fun.(job))
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
