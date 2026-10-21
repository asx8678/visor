defmodule Visor.Harness.Session do
  @moduledoc """
  Supervises one console session: the agent loop, the task supervisor
  its model calls and tool runs execute under, and the feedback collector
  its tools report to.

  The agent is a significant child, so when it stops normally (its owner
  went away) the whole session shuts down with it.
  """
  use Supervisor, restart: :temporary

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    Process.set_label("session #{id}")

    tasks = Visor.Harness.via({id, :tasks})

    children = [
      {Task.Supervisor, name: tasks},
      {Visor.Feedback, id: id},
      Supervisor.child_spec({Visor.Agent, Keyword.put(opts, :tasks, tasks)},
        restart: :transient,
        significant: true
      )
    ]

    Supervisor.init(children, strategy: :one_for_all, auto_shutdown: :any_significant)
  end
end
