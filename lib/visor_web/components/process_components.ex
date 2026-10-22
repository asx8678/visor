defmodule VisorWeb.ProcessComponents do
  @moduledoc """
  The runtime side of the harness view: the header's runtime stats, the
  app strip, the lamp field, the supervision tree and the lifecycle log.
  """
  use VisorWeb, :html

  ## Header

  attr :stats, :map, required: true
  attr :history, :list, required: true
  attr :provider, :map, required: true

  def runtime_header(assigns) do
    ~H"""
    <header
      id="runtime-header"
      class="visor-header flex flex-wrap items-center gap-x-7 gap-y-2 border-b border-rule bg-panel px-4 py-2.5"
    >
      <div class="flex items-baseline gap-2.5">
        <span class="font-display text-[26px] font-semibold leading-none tracking-wide text-ink">
          visor
        </span>
        <span class="text-xs text-ink-dim phone:hidden">{node()}</span>
      </div>

      <dl class="flex flex-wrap items-center gap-x-6 gap-y-1.5">
        <.meter id="stat-processes" label="Processes" value={@stats[:processes]}>
          <:extra><.sparkline points={@history} /></:extra>
        </.meter>
        <.meter
          id="stat-memory"
          label="Memory"
          value={megabytes(@stats[:memory])}
          class="phone:hidden"
        />
        <.meter
          id="stat-reductions"
          label="Reductions"
          value={per_second(@stats[:reductions_per_s])}
          class="phone:hidden"
        />
        <.meter
          id="stat-run-queue"
          label="Run queue"
          value={@stats[:run_queue]}
          class="phone:hidden"
        />
        <.meter
          id="stat-schedulers"
          label="Schedulers"
          value={@stats[:schedulers]}
          class="phone:hidden"
        />
        <.meter
          id="stat-uptime"
          label="Uptime"
          value={duration(@stats[:uptime_ms])}
          class="phone:hidden"
        />
      </dl>

      <div id="provider-badge" class="ml-auto flex items-center gap-2.5 text-sm">
        <span class={["lamp", if(@provider.key == :none, do: "lamp-exit", else: "lamp-idle")]} />
        <span class="font-medium text-ink">{@provider.provider}</span>
        <span class="text-ink-dim phone:hidden">{@provider.model}</span>
        <span :if={@provider.key == :none} class="text-amber phone:hidden">
          No API key: run mix visor.import_deepseek
        </span>
      </div>
    </header>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :class, :any, default: nil
  slot :extra

  defp meter(assigns) do
    ~H"""
    <div id={@id} class={["flex items-center gap-2", @class]}>
      <dt class="text-xs text-ink-dim">{@label}</dt>
      <dd class="font-display text-lg font-medium leading-none text-ink">{@value || "–"}</dd>
      {render_slot(@extra)}
    </div>
    """
  end

  attr :points, :list, required: true

  defp sparkline(assigns) do
    assigns = assign(assigns, :path, sparkline_path(assigns.points, 72, 18))

    ~H"""
    <svg width="72" height="18" viewBox="0 0 72 18" class="overflow-visible" aria-hidden="true">
      <polyline
        :if={@path}
        points={@path}
        fill="none"
        stroke="var(--color-sky)"
        stroke-width="1.25"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  defp sparkline_path(points, _width, _height) when length(points) < 2, do: nil

  defp sparkline_path(points, width, height) do
    {low, high} = Enum.min_max(points)
    span = max(high - low, 4)
    step = width / (length(points) - 1)

    points
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {value, i} ->
      y = height - 1 - (value - low) / span * (height - 2)
      "#{Float.round(i * step, 1)},#{Float.round(y, 1)}"
    end)
  end

  ## Process view

  attr :apps, :list, required: true

  def app_strip(assigns) do
    ~H"""
    <ol id="app-strip" class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs">
      <li class="text-ink-dim">Visor.Supervisor</li>
      <li
        :for={app <- @apps}
        class={[
          "flex items-center gap-1.5",
          if(app.root, do: "text-sky", else: "text-ink-dim")
        ]}
      >
        <span class={["lamp [--lamp-size:6px]", if(app.alive, do: "lamp-idle", else: "lamp-exit")]} />
        {app.label}
      </li>
    </ol>
    """
  end

  attr :lamps, :list, required: true

  def lamp_field(assigns) do
    ~H"""
    <div>
      <div id="lamp-field" class="lamp-field flex min-h-[13px] flex-wrap gap-[7px]" aria-hidden="true">
        <span
          :for={lamp <- @lamps}
          id={"lamp-" <> dom_safe(lamp.id)}
          class={["lamp", "lamp-#{lamp_state(lamp)}"]}
          title={"#{lamp.label} (#{lamp.id})"}
        />
      </div>
      <ul class="mt-2.5 grid grid-cols-3 gap-x-3 gap-y-1 text-xs text-ink-dim">
        <li :for={{state, label} <- lamp_legend()} class="flex items-center gap-1.5">
          <span class={["lamp [--lamp-size:7px]", "lamp-#{state}"]} />{label}
        </li>
      </ul>
    </div>
    """
  end

  defp lamp_legend do
    [
      supervisor: "supervisor",
      idle: "waiting",
      busy: "working",
      model: "model call",
      exit: "exited",
      crash: "crashed"
    ]
  end

  # Model calls get their own colour so they stand out among the tasks.
  defp lamp_state(%{state: state, label: "model turn" <> _}) when state in [:busy, :idle],
    do: :model

  defp lamp_state(%{state: :idle, label: "tool " <> _}), do: :busy
  defp lamp_state(%{state: state}), do: state

  attr :tree, :list, required: true

  def supervision_tree(assigns) do
    ~H"""
    <ul id="supervision-tree" class="text-[13px]">
      <li
        :for={node <- @tree}
        id={"proc-" <> dom_safe(node.id)}
        class="group flex h-[23px] items-stretch pr-1 hover:bg-well"
        title={tree_title(node)}
      >
        <span :for={on <- node.guides} class={["tree-guide", on && "on"]} />
        <span :if={node.depth > 0} class={["tree-elbow", node.last? && "last"]} />
        <span class="flex min-w-0 flex-1 items-center gap-2 pl-1">
          <span class={["lamp", "lamp-#{tree_lamp(node)}"]} />
          <span class={["truncate", label_color(node)]}>{node.label}</span>
          <span :if={node.kind == :supervisor} class="text-xs text-ink-dim">{node.children}</span>
          <span :if={node.queue > 0} class="text-xs text-amber">{node.queue} queued</span>
        </span>
        <span class="flex flex-none items-center gap-3 text-xs text-ink-dim">
          <span class="hidden group-hover:inline">{node.id}</span>
          <span class="w-12 text-right">{kilobytes(node.memory)}</span>
        </span>
      </li>
    </ul>
    """
  end

  # The hover text of a tree row, with the process's Elixir name when the
  # row shows another one. A snapshot taken before a hot reload may not
  # have the name yet.
  defp tree_title(node) do
    name = Map.get(node, :name)
    name = if name && name != node.label, do: " (#{name})", else: ""
    "#{node.label}#{name} #{node.id}, #{node.reductions} reductions"
  end

  defp tree_lamp(node) do
    lamp_state(%{
      label: node.label,
      state:
        cond do
          node.kind == :supervisor -> :supervisor
          node.queue > 0 or node.status == :running or node.activity > 2_000 -> :busy
          true -> :idle
        end
    })
  end

  defp label_color(%{label: "model turn" <> _}), do: "text-sky"
  defp label_color(%{label: "tool " <> _}), do: "text-amber"
  defp label_color(%{kind: :supervisor}), do: "text-ink"
  defp label_color(_node), do: "text-ink/85"

  attr :event, :map, required: true
  attr :id, :string, required: true

  def lifecycle_row(assigns) do
    ~H"""
    <li id={@id} class="grid grid-cols-[86px_54px_minmax(0,1fr)] items-baseline gap-x-2 py-[3px]">
      <span class="text-xs text-ink-dim">{@event.at}</span>
      <span class={["text-xs font-medium", event_color(@event.kind)]}>{event_word(@event.kind)}</span>
      <span class="min-w-0 truncate text-xs">
        <span class={if(@event.kind == :exit, do: "text-ink-dim", else: "text-ink")}>
          {@event.label}
        </span>
        <span class="text-ink-dim">{@event.detail}</span>
      </span>
    </li>
    """
  end

  defp event_word(:spawn), do: "spawn"
  defp event_word(:restart), do: "restart"
  defp event_word(:exit), do: "exit"
  defp event_word(:crash), do: "crash"

  defp event_color(:spawn), do: "text-ink"
  defp event_color(:restart), do: "text-sky"
  defp event_color(:exit), do: "text-ink-dim"
  defp event_color(:crash), do: "text-alarm"

  ## Formatting

  # Ids for DOM elements made from process and call ids.
  def dom_safe(text), do: String.replace(text, ~r/[^A-Za-z0-9_-]/, "-")

  # With its angle brackets, so it reads as a PID and not a version.
  def pid_text(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  def pid_text(_), do: nil

  defp megabytes(nil), do: nil
  defp megabytes(bytes), do: "#{:erlang.float_to_binary(bytes / 1_048_576, decimals: 1)} MB"

  defp kilobytes(bytes) when bytes < 1_048_576, do: "#{div(bytes, 1024)} KB"
  defp kilobytes(bytes), do: megabytes(bytes)

  defp per_second(nil), do: nil

  defp per_second(n) when n >= 1_000_000,
    do: "#{:erlang.float_to_binary(n / 1_000_000, decimals: 1)} M/s"

  defp per_second(n) when n >= 1_000, do: "#{div(n, 1000)} k/s"
  defp per_second(n), do: "#{n}/s"

  defp duration(nil), do: nil
  defp duration(ms) when ms < 60_000, do: "#{div(ms, 1000)} s"
  defp duration(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)} min"
  defp duration(ms), do: "#{div(ms, 3_600_000)} h #{rem(div(ms, 60_000), 60)} min"
end
