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

  @doc "How deep under other agents session `id` runs: 0 for a console's own."
  def depth(id) do
    with store when store != nil <- store(id),
         [{:depth, depth}] <- :ets.lookup(store, :depth) do
      depth
    else
      _ -> 0
    end
  end

  @doc "Whether session `id`'s scripts may only read: a council member's (see `Visor.Jobs`)."
  def read_only?(id) do
    with store when store != nil <- store(id),
         [{:read_only, read_only}] <- :ets.lookup(store, :read_only) do
      read_only
    else
      _ -> false
    end
  end

  @doc """
  The job session `id` runs for, as `"SESSION/JOB"`: a sub-agent's or a
  council member's (see `Visor.Jobs`). Nil for a console's own session,
  or once the session has ended.
  """
  def parent(id) do
    with store when store != nil <- store(id),
         [{:parent, parent}] <- :ets.lookup(store, :parent) do
      parent
    else
      _ -> nil
    end
  rescue
    # The table went with the session, between the lookup and the read.
    ArgumentError -> nil
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
    Process.set_label(Keyword.get(opts, :label, "session #{id}"))

    tasks = Harness.via({id, :tasks})
    store = :ets.new(:visor_session, [:public, read_concurrency: true])
    {:ok, _owner} = Registry.register(Harness.Registry, {id, :store}, store)
    # How deep under other agents this session's agent runs, whether its
    # scripts only read (a council's members), and whose job started it.
    :ets.insert(store, {:depth, Keyword.get(opts, :depth, 0)})
    :ets.insert(store, {:read_only, Keyword.get(opts, :read_only, false)})
    :ets.insert(store, {:parent, Keyword.get(opts, :parent)})

    job_tasks = Harness.via({id, :job_tasks})

    children = [
      {Task.Supervisor, name: tasks},
      {Visor.Feedback, id: id},
      # Idle until the console turns it on; its model calls run under the
      # session's task supervisor.
      {Visor.Reviewer, id: id},
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
