defmodule Visor.Observer do
  @moduledoc """
  Watches the `Visor.Harness` supervision tree for the process view.

  Every process in the tree is traced with an OTP trace session (`:procs`
  with `:set_on_spawn`), so spawns and exits, with their exit reasons, are
  seen even for tasks that live a few milliseconds. The tree itself is
  sampled for memory, queue length, activity and age. A process that
  exited stays in the tree for a few seconds, under the supervisor it ran
  under, with its exit reason and lifetime.

  Broadcasts on `"observer"`:

    * `{:observer, :snapshot, snapshot}` twice a second
    * `{:observer, :events, events}` in small batches as processes come and
      go; `minor` events are processes a script or sandbox started itself
  """
  use GenServer

  alias Visor.Format

  @topic "observer"
  @root Visor.Harness
  @sample_ms 500
  @flush_ms 120
  # Events wait this long before being labelled, so a label sent by the
  # spawner right after the spawn has time to arrive.
  @settle_ms 60
  @history 60
  @ghost_ms 6_000
  @restart_window_ms 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(Visor.PubSub, @topic)

  @doc "The latest snapshot, or nil before the first sample."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc """
  The runtime's statistics as the console shows them (from the last
  sample), with the release versions and the busiest processes.
  """
  def beam_stats do
    Map.merge(snapshot().stats, %{
      process_limit: :erlang.system_info(:process_limit),
      process_memory: :erlang.memory(:processes),
      otp: List.to_string(:erlang.system_info(:otp_release)),
      elixir: System.version(),
      busiest: busiest(8)
    })
  end

  @doc "Gives a process a name for lifecycle events."
  def label(pid, label), do: GenServer.cast(__MODULE__, {:label, pid, label})

  @doc "A readable name for any process."
  def describe(pid) do
    case :proc_lib.get_label(pid) do
      label when is_binary(label) ->
        label

      _ ->
        case Process.info(pid, :registered_name) do
          {:registered_name, name} when is_atom(name) and name != [] -> short(name)
          _ -> initial_call(pid)
        end
    end
  end

  @impl true
  def init(_opts) do
    state = %{
      session: :trace.session_create(:visor, self(), []),
      traced: MapSet.new(),
      labels: %{},
      born: %{},
      parents: %{},
      pending: [],
      reductions: %{},
      total_reductions: elem(:erlang.statistics(:reductions), 0),
      history: [],
      ghosts: %{},
      crashes: %{},
      seq: 0,
      sampled_at: nil,
      snapshot: nil
    }

    send(self(), :sample)
    # Interval timers, not a chain of send_after: while Mix recompiles this
    # module in dev, gen_server drops the messages it can't deliver, and one
    # dropped :sample would end the chain.
    :timer.send_interval(@sample_ms, :sample)
    :timer.send_interval(@flush_ms, :flush)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

  @impl true
  def handle_cast({:label, pid, label}, state) do
    {:noreply, put_in(state.labels[pid], label)}
  end

  @impl true
  def handle_info(:sample, state), do: {:noreply, sample(state)}
  def handle_info(:flush, state), do: {:noreply, flush(state)}

  def handle_info({:trace, parent, :spawn, child, _mfa}, state) do
    {:noreply, %{state | pending: [{:spawn, child, parent, now(), wall()} | state.pending]}}
  end

  def handle_info({:trace, pid, :exit, reason}, state) do
    {:noreply, %{state | pending: [{:exit, pid, reason, now(), wall()} | state.pending]}}
  end

  # Links, unlinks and the child-side :spawned message.
  def handle_info({:trace, _, _, _}, state), do: {:noreply, state}
  def handle_info({:trace, _, _, _, _}, state), do: {:noreply, state}

  defp sample(state) do
    root = Process.whereis(@root)
    now = now()
    # Rates run over the time since the last sample, which is longer than
    # the interval when this process was busy or Mix recompiled it.
    elapsed = max(now - (Map.get(state, :sampled_at) || now - @sample_ms), 1)
    ghosts = Map.filter(state.ghosts, fn {_pid, ghost} -> now - ghost.at < @ghost_ms end)

    # Exited processes go back in under the supervisor they ran under.
    exited =
      ghosts
      |> Enum.map(fn {pid, ghost} -> {pid, %{type: :ghost, ghost: ghost}} end)
      |> Enum.group_by(fn {_pid, meta} -> meta.ghost.parent end)

    nodes =
      if root,
        do: collect(root, %{id: @root, type: :supervisor, modules: []}, 0, [], true, exited),
        else: []

    live_nodes = Enum.reject(nodes, &Map.has_key?(&1, :ghost))

    # Trace anything in the tree not traced yet (processes started before
    # the observer, or after a restart of the tree).
    live = MapSet.new(live_nodes, & &1.pid)

    for pid <- MapSet.difference(live, state.traced) do
      :trace.process(state.session, pid, true, [:procs, :set_on_spawn])
    end

    # A process's age runs from its spawn. One that started before the
    # observer, or under a supervisor it doesn't trace, has none.
    born = Enum.reduce(live_nodes, state.born, &Map.put_new(&2, &1.pid, nil))

    nodes =
      Enum.map(nodes, fn
        %{ghost: _} = node ->
          node

        node ->
          Map.merge(node, %{
            activity: activity(node, state.reductions, elapsed),
            age_ms: if(spawned = born[node.pid], do: now - spawned)
          })
      end)

    {total, _} = :erlang.statistics(:reductions)
    history = Enum.take([:erlang.system_info(:process_count) | state.history], @history)

    snapshot = %{
      tree: nodes,
      stats: stats(total - state.total_reductions, elapsed),
      apps: apps(),
      history: Enum.reverse(history)
    }

    Phoenix.PubSub.broadcast(Visor.PubSub, @topic, {:observer, :snapshot, snapshot})

    keep =
      MapSet.union(live, MapSet.new(Map.keys(ghosts) ++ Enum.map(state.pending, &elem(&1, 1))))

    labels = Map.merge(state.labels, Map.new(live_nodes, &{&1.pid, &1.label}))
    parents = Map.merge(state.parents, Map.new(live_nodes, &{&1.pid, &1.parent}))
    keep? = fn {pid, _} -> MapSet.member?(keep, pid) end

    %{
      state
      | traced: live,
        reductions: Map.new(live_nodes, &{&1.pid, &1.reductions}),
        total_reductions: total,
        history: history,
        ghosts: ghosts,
        labels: Map.filter(labels, keep?),
        born: Map.filter(born, keep?),
        parents: Map.filter(parents, keep?),
        crashes: Map.filter(state.crashes, fn {_label, at} -> now - at < @restart_window_ms end),
        snapshot: snapshot
    }
    |> Map.put(:sampled_at, now)
  end

  defp collect(pid, meta, depth, guides, last?, exited, parent \\ nil) do
    children =
      if meta.type == :supervisor,
        do: with_exited(children(pid), Map.get(exited, pid, [])),
        else: []

    count = length(children)
    live = Enum.count(children, fn {_pid, child_meta} -> child_meta.type != :ghost end)
    child_guides = if depth == 0, do: [], else: guides ++ [not last?]

    descendants =
      children
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {{child, child_meta}, i} ->
        collect(child, child_meta, depth + 1, child_guides, i == count, exited, pid)
      end)

    [node(pid, meta, {depth, guides, last?, parent}, live) | descendants]
  end

  defp children(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.flat_map(fn
      {id, pid, type, modules} when is_pid(pid) ->
        [{pid, %{id: id, type: type, modules: modules}}]

      _restarting ->
        []
    end)
  catch
    :exit, _ -> []
  end

  @doc false
  # A supervisor's live children and the ones that exited lately, in spawn
  # order, so rows keep their places as processes come and go. A child the
  # supervisor still lists counts as live.
  def with_exited(children, exited) do
    (children ++ exited)
    |> Enum.uniq_by(fn {pid, _meta} -> pid end)
    |> Enum.sort_by(fn {pid, _meta} -> pid end)
  end

  defp node(pid, %{type: :ghost, ghost: ghost}, {depth, guides, last?, parent}, _count) do
    %{
      pid: pid,
      id: pid_id(pid),
      label: ghost.label,
      name: nil,
      kind: :exited,
      depth: depth,
      guides: guides,
      last?: last?,
      parent: parent,
      children: 0,
      memory: 0,
      queue: 0,
      reductions: 0,
      status: :exited,
      activity: 0,
      age_ms: ghost.lifetime_ms,
      ghost: %{kind: ghost.kind, reason: ghost.reason}
    }
  end

  defp node(pid, meta, {depth, guides, last?, parent}, count) do
    info = Process.info(pid, [:memory, :message_queue_len, :reductions, :status]) || []

    %{
      pid: pid,
      id: pid_id(pid),
      label: node_label(pid, meta),
      name: elixir_name(pid, meta),
      kind: kind(meta),
      depth: depth,
      guides: guides,
      last?: last?,
      parent: parent,
      children: count,
      memory: info[:memory] || 0,
      queue: info[:message_queue_len] || 0,
      reductions: info[:reductions] || 0,
      status: info[:status]
    }
  end

  defp node_label(pid, meta) do
    case :proc_lib.get_label(pid) do
      label when is_binary(label) ->
        label

      _ ->
        case meta do
          %{modules: [Task.Supervisor]} -> "tasks"
          %{id: id} when is_atom(id) and id != :undefined -> short(id)
          _ -> describe(pid)
        end
    end
  end

  defp kind(%{type: :supervisor}), do: :supervisor
  defp kind(%{modules: [Task.Supervised]}), do: :task
  defp kind(_meta), do: :worker

  # Reductions per second since the last sample.
  defp activity(node, previous, elapsed) do
    case Map.fetch(previous, node.pid) do
      {:ok, before} -> div(max(node.reductions - before, 0) * 1000, elapsed)
      :error -> 0
    end
  end

  defp stats(reductions, elapsed) do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    %{
      processes: :erlang.system_info(:process_count),
      memory: :erlang.memory(:total),
      run_queue: :erlang.statistics(:total_run_queue_lengths),
      schedulers: :erlang.system_info(:schedulers_online),
      uptime_ms: uptime_ms,
      reductions_per_s: div(reductions * 1000, elapsed)
    }
  end

  # The processes that have run the most, by reductions since they started.
  defp busiest(n) do
    Process.list()
    |> Enum.flat_map(fn pid ->
      case Process.info(pid, [:reductions, :memory, :message_queue_len]) do
        nil -> []
        info -> [{pid, info}]
      end
    end)
    |> Enum.sort_by(fn {_pid, info} -> -info[:reductions] end)
    |> Enum.take(n)
    |> Enum.map(fn {pid, info} ->
      %{
        name: describe(pid),
        pid: inspect(pid),
        reductions: info[:reductions],
        memory: info[:memory],
        queue: info[:message_queue_len]
      }
    end)
  end

  defp apps do
    case Process.whereis(Visor.Supervisor) do
      nil ->
        []

      sup ->
        for {id, pid, type, _modules} <- Supervisor.which_children(sup) do
          %{
            label: short(id),
            alive: is_pid(pid),
            supervisor: type == :supervisor,
            root: id == @root
          }
        end
        |> Enum.reverse()
    end
  catch
    :exit, _ -> []
  end

  defp flush(%{pending: []} = state), do: state

  defp flush(state) do
    cutoff = now() - @settle_ms
    {ready, waiting} = Enum.split_with(state.pending, fn event -> elem(event, 3) <= cutoff end)

    {events, state} =
      ready
      |> Enum.reverse()
      |> Enum.map_reduce(%{state | pending: waiting}, &lifecycle_event/2)

    if events != [] do
      Phoenix.PubSub.broadcast(Visor.PubSub, @topic, {:observer, :events, events})
    end

    state
  end

  defp lifecycle_event({:spawn, pid, parent, at, wall}, state) do
    label = Map.get_lazy(state.labels, pid, fn -> describe(pid) end)
    restart? = Map.has_key?(state.crashes, label)

    event = %{
      id: state.seq,
      kind: if(restart?, do: :restart, else: :spawn),
      minor: not supervised?(parent),
      pid: pid_id(pid),
      label: label,
      detail: "from " <> Map.get_lazy(state.labels, parent, fn -> describe(parent) end),
      at: clock(wall)
    }

    {event,
     %{
       state
       | seq: state.seq + 1,
         labels: Map.put(state.labels, pid, label),
         parents: Map.put(state.parents, pid, parent),
         born: Map.put(state.born, pid, at),
         crashes: if(restart?, do: Map.delete(state.crashes, label), else: state.crashes)
     }}
  end

  defp lifecycle_event({:exit, pid, reason, at, wall}, state) do
    label = Map.get(state.labels, pid, "process")
    kind = if clean_exit?(reason), do: :exit, else: :crash
    lifetime = if born = state.born[pid], do: at - born
    reason = reason_text(reason)

    event = %{
      id: state.seq,
      kind: kind,
      minor: kind == :exit and not supervised?(state.parents[pid]),
      pid: pid_id(pid),
      label: label,
      detail: reason <> if(lifetime, do: " after #{Format.seconds(lifetime)}", else: ""),
      at: clock(wall)
    }

    ghost = %{
      label: label,
      kind: kind,
      at: at,
      reason: reason,
      lifetime_ms: lifetime,
      parent: state.parents[pid]
    }

    {event,
     %{
       state
       | seq: state.seq + 1,
         ghosts: Map.put(state.ghosts, pid, ghost),
         crashes: if(kind == :crash, do: Map.put(state.crashes, label, at), else: state.crashes)
     }}
  end

  # Whether a supervisor started the process. The ones a script or sandbox
  # starts for itself are minor events. The tree's processes always have a
  # parent on record; others lose theirs at the next sample.
  defp supervised?(nil), do: false
  defp supervised?(parent), do: match?({:supervisor, _, _}, :proc_lib.initial_call(parent))

  defp clean_exit?(reason), do: reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)

  defp reason_text(:normal), do: "normal"
  defp reason_text(:shutdown), do: "shutdown"
  defp reason_text({:shutdown, _}), do: "shutdown"
  defp reason_text(:killed), do: "killed"

  defp reason_text(reason) do
    reason |> Exception.format_exit() |> String.split("\n") |> hd() |> String.slice(0, 120)
  end

  defp initial_call(pid) do
    case :proc_lib.initial_call(pid) do
      {:supervisor, Task.Supervisor, _args} -> "tasks"
      {:supervisor, module, _args} -> short(module)
      {module, _fun, _args} -> short(module)
      false -> "process"
    end
  end

  defp short(module) when is_atom(module) do
    module |> inspect() |> String.replace_prefix("Visor.Harness.", "") |> plain()
  end

  defp short(other), do: inspect(other)

  # Elixir's names for the harness registry and its worker say little, so
  # the tree shows what they do; the tooltip keeps the Elixir name.
  defp plain("Registry"), do: "Process names"
  defp plain("Registry.PIDPartition0"), do: "name cleanup"
  defp plain("Registry.PIDPartition" <> n), do: "name cleanup #{n}"
  defp plain(name), do: name

  # The name Elixir knows a process by, for the tree's tooltip.
  defp elixir_name(pid, meta) do
    case meta do
      %{id: id} when is_atom(id) and id != :undefined ->
        inspect(id)

      _ ->
        case Process.info(pid, :registered_name) do
          {:registered_name, name} when is_atom(name) and name != [] -> inspect(name)
          _ -> nil
        end
    end
  end

  defp pid_id(pid) do
    pid
    |> :erlang.pid_to_list()
    |> List.to_string()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
  end

  defp clock(wall) do
    {_date, {h, m, s}} = :calendar.system_time_to_local_time(wall, :millisecond)

    :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [h, m, s, rem(wall, 1000)])
    |> IO.iodata_to_binary()
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp wall, do: System.system_time(:millisecond)
end
