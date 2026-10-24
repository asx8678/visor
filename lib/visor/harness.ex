defmodule Visor.Harness do
  @moduledoc """
  The supervision tree every agent session runs under.

      Visor.Harness
      ├── Visor.Harness.Registry
      └── Visor.Harness.Sessions   (one Visor.Harness.Session per console)

  `Visor.Observer` traces this subtree, so anything started here shows up
  in the process view.
  """
  use Supervisor

  alias Visor.Harness.Session

  @registry Visor.Harness.Registry
  @sessions Visor.Harness.Sessions

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @sessions, strategy: :one_for_one}
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
    # A sub-agent's session (see Visor.Jobs) takes these from its parent.
    child = Keyword.take(opts, [:max_steps, :role, :depth, :label, :read_only])

    case DynamicSupervisor.start_child(@sessions, {Session, [id: id, owner: owner] ++ child}) do
      {:ok, pid} ->
        log_dir = Keyword.get_lazy(opts, :log_dir, &Visor.SessionLog.dir/0)
        Visor.SessionLog.start(id, owner, pid, log_dir, Keyword.get(opts, :parent))
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

  defp random_id do
    :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
  end
end
