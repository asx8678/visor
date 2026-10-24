defmodule Visor.Harness.Session do
  @moduledoc """
  Supervises one console session: the agent loop, the task supervisor
  its model calls and tool runs execute under, and the feedback collector
  its tools report to.

  The conversation lives in a table this supervisor owns (see
  `store/1`), so a crash of the agent or of the feedback collector costs
  neither the conversation: each child restarts on its own and the agent
  picks up where it was.

  The agent is a significant child, so when it stops normally (its owner
  went away) the whole session shuts down with it.
  """
  use Supervisor, restart: :temporary

  alias Visor.Harness

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @doc "The table session `id` keeps its conversation in, or nil."
  def store(id) do
    case Registry.lookup(Harness.Registry, {id, :store}) do
      [{_supervisor, store}] -> store
      [] -> nil
    end
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    Process.set_label("session #{id}")

    tasks = Harness.via({id, :tasks})
    store = :ets.new(:visor_session, [:public, read_concurrency: true])
    {:ok, _owner} = Registry.register(Harness.Registry, {id, :store}, store)

    job_tasks = Harness.via({id, :job_tasks})

    children = [
      {Task.Supervisor, name: tasks},
      {Visor.Feedback, id: id},
      # Stopped after the agent and the jobs server, and with them each
      # job's command.
      {Task.Supervisor, name: job_tasks},
      {Visor.Jobs, id: id, tasks: job_tasks},
      Supervisor.child_spec({Visor.Agent, Keyword.merge(opts, tasks: tasks, store: store)},
        restart: :transient,
        significant: true
      )
    ]

    Supervisor.init(children, strategy: :one_for_one, auto_shutdown: :any_significant)
  end
end
