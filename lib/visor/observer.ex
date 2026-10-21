defmodule Visor.Observer do
  @moduledoc """
  Watches the `Visor.Harness` supervision tree for the process view.

  Every process in the tree is traced with an OTP trace session (`:procs`
  with `:set_on_spawn`), so spawns and exits, with their exit reasons, are
  seen even for tasks that live a few milliseconds. The tree itself is
  sampled for memory, queue length and activity.

  Broadcasts on `"observer"`:

    * `{:observer, :snapshot, snapshot}` twice a second
    * `{:observer, :events, events}` in small batches as processes come and go
  """
  use GenServer

  @topic "observer"
  @root Visor.Harness
  @sample_ms 500
  @flush_ms 120
  # Events wait this long before being labelled, so a label sent by the
  # spawner right after the spawn has time to arrive.
  @settle_ms 60
  @history 60
  @ghost_ms 4_000
  @restart_window_ms 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(Visor.PubSub, @topic)

  @doc "The latest snapshot, or nil before the first sample."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

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
      pending: [],
      reductions: %{},
      total_reductions: elem(:erlang.statistics(:reductions), 0),
      history: [],
      ghosts: %{},
      crashes: %{},
      seq: 0,
      snapshot: nil
    }

    send(self(), :sample)
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
  def handle_info(:sample, state) do
    Process.send_after(self(), :sample, @sample_ms)
    {:noreply, sample(state)}
  end

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

    nodes =
      if root,
        do: collect(root, %{id: @root, type: :supervisor, modules: []}, 0, [], true),
        else: []

    # Trace anything in the tree not traced yet (processes started before
    # the observer, or after a restart of the tree).
    live = MapSet.new(nodes, & &1.pid)

    for pid <- MapSet.difference(live, state.traced) do
      :trace.process(state.session, pid, true, [:procs, :set_on_spawn])
    end

    nodes = Enum.map(nodes, &Map.put(&1, :activity, activity(&1, state.reductions)))
    {total, _} = :erlang.statistics(:reductions)
    now = now()
    ghosts = Map.filter(state.ghosts, fn {_pid, ghost} -> now - ghost.at < @ghost_ms end)
    history = Enum.take([:erlang.system_info(:process_count) | state.history], @history)

    snapshot = %{
      tree: nodes,
      lamps: lamps(nodes, ghosts),
      stats: stats(total - state.total_reductions),
      apps: apps(),
      history: Enum.reverse(history)
    }

    Phoenix.PubSub.broadcast(Visor.PubSub, @topic, {:observer, :snapshot, snapshot})

    keep =
      MapSet.union(live, MapSet.new(Map.keys(ghosts) ++ Enum.map(state.pending, &elem(&1, 1))))

    labels = Map.merge(state.labels, Map.new(nodes, &{&1.pid, &1.label}))

    %{
      state
      | traced: live,
        reductions: Map.new(nodes, &{&1.pid, &1.reductions}),
        total_reductions: total,
        history: history,
        ghosts: ghosts,
        labels: Map.filter(labels, fn {pid, _} -> MapSet.member?(keep, pid) end),
        born: Map.filter(state.born, fn {pid, _} -> MapSet.member?(keep, pid) end),
        crashes: Map.filter(state.crashes, fn {_label, at} -> now - at < @restart_window_ms end),
        snapshot: snapshot
    }
  end

  defp collect(pid, meta, depth, guides, last?) do
    children = if meta.type == :supervisor, do: children(pid), else: []
    count = length(children)
    child_guides = if depth == 0, do: [], else: guides ++ [not last?]

    descendants =
      children
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {{child, child_meta}, i} ->
        collect(child, child_meta, depth + 1, child_guides, i == count)
      end)

    [node(pid, meta, depth, guides, last?, count) | descendants]
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
    |> Enum.sort_by(fn {pid, _meta} -> pid end)
  catch
    :exit, _ -> []
  end

  defp node(pid, meta, depth, guides, last?, count) do
    info = Process.info(pid, [:memory, :message_queue_len, :reductions, :status]) || []

    %{
      pid: pid,
      id: pid_id(pid),
      label: node_label(pid, meta),
      kind: kind(meta),
      depth: depth,
      guides: guides,
      last?: last?,
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
  defp activity(node, previous) do
    case Map.fetch(previous, node.pid) do
      {:ok, before} -> div(max(node.reductions - before, 0) * 1000, @sample_ms)
      :error -> 0
    end
  end

  defp lamps(nodes, ghosts) do
    live =
      for node <- nodes, node.depth > 0 do
        state =
          cond do
            node.kind == :supervisor -> :supervisor
            node.queue > 0 or node.status == :running or node.activity > 2_000 -> :busy
            true -> :idle
          end

        {node.pid, %{id: node.id, label: node.label, state: state}}
      end

    gone =
      for {pid, ghost} <- ghosts,
          do: {pid, %{id: pid_id(pid), label: ghost.label, state: ghost.kind}}

    (live ++ gone)
    |> Enum.uniq_by(fn {pid, _} -> pid end)
    |> Enum.sort_by(fn {pid, _} -> pid end)
    |> Enum.map(fn {_pid, lamp} -> lamp end)
  end

  defp stats(reductions) do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    %{
      processes: :erlang.system_info(:process_count),
      memory: :erlang.memory(:total),
      run_queue: :erlang.statistics(:total_run_queue_lengths),
      schedulers: :erlang.system_info(:schedulers_online),
      uptime_ms: uptime_ms,
      reductions_per_s: div(reductions * 1000, @sample_ms)
    }
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
         born: Map.put(state.born, pid, at),
         crashes: if(restart?, do: Map.delete(state.crashes, label), else: state.crashes)
     }}
  end

  defp lifecycle_event({:exit, pid, reason, at, wall}, state) do
    label = Map.get(state.labels, pid, "process")
    kind = if clean_exit?(reason), do: :exit, else: :crash
    lifetime = if born = state.born[pid], do: " after #{format_ms(at - born)}"

    event = %{
      id: state.seq,
      kind: kind,
      pid: pid_id(pid),
      label: label,
      detail: reason_text(reason) <> (lifetime || ""),
      at: clock(wall)
    }

    {event,
     %{
       state
       | seq: state.seq + 1,
         ghosts: Map.put(state.ghosts, pid, %{label: label, kind: kind, at: at}),
         crashes: if(kind == :crash, do: Map.put(state.crashes, label, at), else: state.crashes)
     }}
  end

  defp clean_exit?(reason), do: reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)

  defp reason_text(:normal), do: "normal"
  defp reason_text(:shutdown), do: "shutdown"
  defp reason_text({:shutdown, _}), do: "shutdown"
  defp reason_text(:killed), do: "killed"

  defp reason_text(reason) do
    reason |> Exception.format_exit() |> String.split("\n") |> hd() |> String.slice(0, 120)
  end

  defp format_ms(ms) when ms < 1000, do: "#{ms} ms"
  defp format_ms(ms), do: "#{Float.round(ms / 1000, 1)} s"

  defp initial_call(pid) do
    case :proc_lib.initial_call(pid) do
      {:supervisor, Task.Supervisor, _args} -> "tasks"
      {:supervisor, module, _args} -> short(module)
      {module, _fun, _args} -> short(module)
      false -> "process"
    end
  end

  defp short(module) when is_atom(module) do
    module |> inspect() |> String.replace_prefix("Visor.Harness.", "")
  end

  defp short(other), do: inspect(other)

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
