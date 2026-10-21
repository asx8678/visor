defmodule Visor.Harness do
  @moduledoc """
  The supervision tree every agent session and worker runs under.

      Visor.Harness
      ├── Visor.Harness.Registry
      ├── Visor.Harness.Sessions   (one Visor.Harness.Session per console)
      └── Visor.Harness.Workers    (demo workers started with /spawn)

  `Visor.Observer` traces this subtree, so anything started here shows up
  in the process view.
  """
  use Supervisor

  alias Visor.Harness.{Session, Worker}

  @registry Visor.Harness.Registry
  @sessions Visor.Harness.Sessions
  @workers Visor.Harness.Workers

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :persistent_term.put({__MODULE__, :worker_counter}, :counters.new(1, []))

    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @sessions, strategy: :one_for_one},
      {DynamicSupervisor, name: @workers, strategy: :one_for_one, max_restarts: 50}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Names a process inside the harness registry."
  def via(key), do: {:via, Registry, {@registry, key}}

  @doc """
  Starts a new agent session owned by `owner`. The session stops when the
  owner process exits.

  The session is logged to `:log_dir` (default `Visor.SessionLog.dir/0`);
  see `Visor.SessionLog`.
  """
  def start_session(owner, opts \\ []) do
    id = random_id()

    case DynamicSupervisor.start_child(@sessions, {Session, id: id, owner: owner}) do
      {:ok, pid} ->
        log_dir = Keyword.get_lazy(opts, :log_dir, &Visor.SessionLog.dir/0)
        Visor.SessionLog.start(id, owner, pid, log_dir)
        {:ok, id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Starts a supervised task, labelled for the process view.
  """
  def async(task_supervisor, label, fun) do
    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Process.set_label(label)
        fun.()
      end)

    Visor.Observer.label(task.pid, label)
    task
  end

  @doc "Starts `count` demo workers that each live for `duration_ms`."
  def spawn_workers(count, duration_ms) do
    counter = :persistent_term.get({__MODULE__, :worker_counter})

    for _ <- 1..count do
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      {:ok, pid} =
        DynamicSupervisor.start_child(@workers, {Worker, n: n, duration_ms: duration_ms})

      pid
    end
  end

  @doc """
  Kills a random demo worker. Its supervisor restarts it, which shows up
  in the process view as an exit followed by a restart.
  """
  def crash_worker do
    case for({_, pid, _, _} <- DynamicSupervisor.which_children(@workers), is_pid(pid), do: pid) do
      [] ->
        {:error, :no_workers}

      pids ->
        pid = Enum.random(pids)
        label = :proc_lib.get_label(pid)
        Process.exit(pid, :kill)
        {:ok, label}
    end
  end

  defp random_id do
    :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
  end
end
