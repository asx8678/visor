defmodule VisorWeb.ProcessComponents do
  @moduledoc """
  The runtime side of the harness view: the header's runtime stats, the
  app strip, the prompt timeline, the supervision tree and the lifecycle
  log.
  """
  use VisorWeb, :html

  alias VisorWeb.ModelCall

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

  # The top supervisor's children, folded to one line.
  def app_strip(assigns) do
    assigns = assign(assigns, :down, Enum.count(assigns.apps, &(not &1.alive)))

    ~H"""
    <details id="app-strip" class="group/fold text-xs" phx-mounted={JS.ignore_attributes(["open"])}>
      <summary class="flex cursor-pointer list-none items-center gap-1 text-ink-dim hover:text-ink">
        <.icon
          name="hero-chevron-right-micro"
          class="size-3.5 flex-none transition-transform group-open/fold:rotate-90"
        />
        <span>Visor.Supervisor · {length(@apps)} children</span>
        <span :if={@down > 0} class="text-alarm">· {@down} down</span>
      </summary>
      <ol class="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 pl-[18px]">
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
    </details>
    """
  end

  attr :work, :map, default: nil
  attr :now, :integer, required: true

  # Where the running prompt's time goes: its model calls and tool calls
  # as bars from the prompt's start, the running ones in colour. Stays on
  # the last prompt until the next one.
  def prompt_timeline(assigns) do
    assigns = assign(assigns, :timeline, timeline(assigns.work, assigns.now))

    ~H"""
    <div id="prompt-timeline" class="text-xs text-ink-dim">
      <p :if={!@timeline}>A prompt's model and tool calls show here as it runs.</p>
      <div :if={@timeline}>
        <div class="flex items-baseline gap-1.5">
          <span>{if(@timeline.running?, do: "This prompt", else: "Last prompt")}</span>
          <span class="text-ink/85">{seconds(@timeline.total)}</span>
          <span
            id="timeline-split"
            class="ml-auto truncate"
            title={"#{count(length(@timeline.model), "model call")}, #{count(length(@timeline.tools), "tool call")}, #{seconds(@timeline.between_ms)} between them"}
          >
            model {seconds(@timeline.model_ms)} · tools {seconds(@timeline.tool_ms)}
          </span>
        </div>
        <div class="mt-1.5 grid grid-cols-[30px_minmax(0,1fr)] items-center gap-x-2 gap-y-1 text-[11px]">
          <span>model</span>
          <.timeline_lane id="timeline-model" spans={@timeline.model} />
          <span>tools</span>
          <.timeline_lane id="timeline-tools" spans={@timeline.tools} />
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :spans, :list, required: true

  defp timeline_lane(assigns) do
    ~H"""
    <div id={@id} class="relative h-1.5 overflow-hidden rounded-[1px] bg-well">
      <span
        :for={span <- @spans}
        id={"#{@id}-#{dom_safe(span.id)}"}
        data-state={span.state}
        class={[
          "absolute inset-y-0 min-w-0.5",
          span_color(span)
        ]}
        style={"left: #{span.left}%; width: #{span.width}%"}
        title={span.title}
      />
    </div>
    """
  end

  defp span_color(%{state: :error}), do: "bg-alarm"
  defp span_color(%{state: :running, kind: :model}), do: "bg-sky"
  defp span_color(%{state: :running, kind: :tool}), do: "bg-amber"
  defp span_color(_span), do: "bg-idle/45"

  defp timeline(nil, _now), do: nil

  defp timeline(work, now) do
    finished = if work.ms, do: work.started + work.ms

    spans =
      Enum.flat_map(work.steps, fn
        %{type: :turn, started: started} = turn ->
          [
            %{
              id: turn.id,
              kind: :model,
              start: started,
              ms: turn.stats && turn.stats[:ms],
              state:
                cond do
                  turn.streaming and !finished -> :running
                  turn.streaming -> :done
                  ModelCall.failed?(turn.finish_reason) -> :error
                  true -> :done
                end,
              title: "model call #{turn.turn}" <> turn_note(turn)
            }
          ]

        %{type: :tool, started: started} = tool ->
          [
            %{
              id: tool.id,
              kind: :tool,
              start: started,
              ms: tool.ms,
              state:
                case tool.status do
                  :running -> if finished, do: :done, else: :running
                  :error -> :error
                  _ok -> :done
                end,
              title: tool.name <> tool_note(tool)
            }
          ]

        _step ->
          []
      end)

    # The clock moves with the runtime snapshots, so a call may have
    # started or ended after it: the scale runs to whichever is later.
    stop = finished || Enum.max([now | Enum.map(spans, &(&1.start + (&1.ms || 0)))])
    total = max(stop - work.started, 1)

    spans =
      Enum.map(spans, fn span ->
        ms = span.ms || stop - span.start
        left = percent(span.start - work.started, total)

        %{
          span
          | ms: ms,
            title: "#{span.title} · #{seconds(ms)}"
        }
        |> Map.merge(%{left: left, width: min(percent(ms, total), 100 - left)})
      end)

    {model, tools} = Enum.split_with(spans, &(&1.kind == :model))

    %{
      running?: !finished,
      total: total,
      model: model,
      tools: tools,
      model_ms: covered(model),
      tool_ms: covered(tools),
      between_ms: max(total - covered(spans), 0)
    }
  end

  defp turn_note(%{streaming: true}), do: ""
  defp turn_note(%{finish_reason: reason}), do: ", " <> ModelCall.finish_text(reason)

  defp tool_note(%{calls: [_ | _] = calls, call_count: n}) do
    shown = calls |> Enum.take(3) |> Enum.map_join(", ", &("V." <> &1.text))
    more = if n > 3, do: " and #{n - 3} more", else: ""
    ": " <> shown <> more
  end

  defp tool_note(_tool), do: ""

  # The time spans cover, counting overlaps once.
  defp covered(spans) do
    spans
    |> Enum.map(&{&1.start, &1.start + &1.ms})
    |> Enum.sort()
    |> Enum.reduce({0, nil}, fn
      {from, to}, {sum, nil} -> {sum, {from, to}}
      {from, to}, {sum, {a, b}} when from <= b -> {sum, {a, max(b, to)}}
      {from, to}, {sum, {a, b}} -> {sum + b - a, {from, to}}
    end)
    |> then(fn
      {sum, nil} -> sum
      {sum, {a, b}} -> sum + b - a
    end)
  end

  defp percent(part, whole), do: Float.round(min(max(part, 0) * 100 / whole, 100.0), 2)

  attr :tree, :list, required: true
  # What the session's processes are doing, by pid text or label.
  attr :activity, :map, default: %{}

  def supervision_tree(assigns) do
    ~H"""
    <ul id="supervision-tree" class="text-[13px]">
      <li
        :for={node <- @tree}
        id={"proc-" <> dom_safe(node.id)}
        class={[
          "group flex items-stretch pr-1 hover:bg-well",
          Map.has_key?(node, :ghost) && "tree-gone"
        ]}
        title={tree_title(node)}
      >
        <span :for={on <- node.guides} class={["tree-guide", on && "on"]} />
        <span :if={node.depth > 0} class={["tree-elbow", node.last? && "last"]} />
        <div class="min-w-0 flex-1">
          <div class="flex h-[23px] items-center gap-3">
            <span class="flex min-w-0 flex-1 items-center gap-2 pl-1">
              <span class={["lamp", "lamp-#{tree_lamp(node)}"]} />
              <span class={[
                "truncate",
                Map.has_key?(node, :ghost) && "flex-none",
                label_color(node)
              ]}>
                {node.label}
              </span>
              <%= case Map.get(node, :ghost) do %>
                <% nil -> %>
                  <span :if={row_note(@activity, node)} class="truncate text-xs text-ink-dim">
                    {row_note(@activity, node)}
                  </span>
                  <span :if={node.queue > 0} class="text-xs text-amber">{node.queue} queued</span>
                <% ghost -> %>
                  <span class={[
                    "min-w-0 truncate text-xs",
                    if(ghost.kind == :crash, do: "text-alarm", else: "text-ink-dim")
                  ]}>
                    {ghost_text(ghost)}{if(node.age_ms, do: " after #{seconds(node.age_ms)}")}
                  </span>
              <% end %>
            </span>
            <span class="flex flex-none items-center gap-3 text-xs text-ink-dim">
              <span :if={busy?(node)} class="text-ink/85">{cpu(node)}</span>
              <span class="w-12 text-right">{if(node.memory > 0, do: kilobytes(node.memory))}</span>
            </span>
          </div>
          <.doing node={node} doing={row_activity(@activity, node)} />
        </div>
      </li>
    </ul>
    """
  end

  attr :node, :map, required: true
  attr :doing, :map, default: nil

  # A tree row's second line: what the process is doing right now.
  defp doing(assigns) do
    ~H"""
    <p
      :if={@doing}
      id={"doing-" <> dom_safe(@node.id)}
      class={["-mt-1 truncate pb-1 pl-[22px] text-xs", activity_color(@doing.tone)]}
    >
      {@doing.text}
    </p>
    """
  end

  defp ghost_text(%{kind: :crash, reason: reason}), do: reason
  defp ghost_text(%{reason: "normal"}), do: "exited"
  defp ghost_text(%{reason: "shutdown"}), do: "shut down"
  defp ghost_text(%{reason: reason}), do: reason

  # Plain notes, such as which session is this tab's, sit after the label;
  # what a working process does gets the line below it.
  defp row_note(activity, node) do
    case lookup(activity, node) do
      %{inline: true, text: text} -> text
      _other -> nil
    end
  end

  defp row_activity(activity, node) do
    case lookup(activity, node) do
      %{inline: true} -> nil
      doing -> doing
    end
  end

  defp lookup(_activity, %{ghost: _}), do: nil
  defp lookup(activity, node), do: activity[pid_text(node.pid)] || activity[node.label]

  defp activity_color(:model), do: "text-sky"
  defp activity_color(:tool), do: "text-amber"
  defp activity_color(_tone), do: "text-ink-dim"

  # The hover text of a tree row, with the process's Elixir name when the
  # row shows another one. A snapshot taken before a hot reload may not
  # have the name yet.
  defp tree_title(%{ghost: ghost} = node),
    do:
      "#{node.label} #{node.id}, #{if(ghost.kind == :crash, do: "crashed", else: "exited")}: #{ghost.reason}"

  defp tree_title(node) do
    name = Map.get(node, :name)
    name = if name && name != node.label, do: " (#{name})", else: ""
    age = if ms = Map.get(node, :age_ms), do: ", up #{age(ms)}", else: ""

    children =
      case node do
        %{kind: :supervisor, children: 1} -> ", 1 child"
        %{kind: :supervisor, children: n} -> ", #{n} children"
        _worker -> ""
      end

    "#{node.label}#{name} #{node.id}#{children}#{age}, " <>
      "#{number(Map.get(node, :activity, 0))} reductions a second"
  end

  defp tree_lamp(%{ghost: %{kind: :crash}}), do: :crash
  defp tree_lamp(%{ghost: _}), do: :exit

  defp tree_lamp(node) do
    lamp_state(%{
      label: node.label,
      state:
        cond do
          node.kind == :supervisor -> :supervisor
          busy?(node) -> :busy
          true -> :idle
        end
    })
  end

  defp busy?(%{ghost: _}), do: false

  defp busy?(node),
    do: node.queue > 0 or node.status == :running or Map.get(node, :activity, 0) > 2_000

  # Model calls get their own colour so they stand out among the tasks.
  defp lamp_state(%{state: state, label: "model turn" <> _}) when state in [:busy, :idle],
    do: :model

  defp lamp_state(%{state: :idle, label: "tool " <> _}), do: :busy
  defp lamp_state(%{state: state}), do: state

  defp label_color(%{ghost: _}), do: "text-ink-dim"
  defp label_color(%{label: "model turn" <> _}), do: "text-sky"
  defp label_color(%{label: "tool " <> _}), do: "text-amber"
  defp label_color(%{kind: :supervisor}), do: "text-ink"
  defp label_color(_node), do: "text-ink/85"

  # Reductions a second, the BEAM's measure of work done.
  defp cpu(node), do: "#{short(Map.get(node, :activity, 0))}/s"

  # A process's age, in its largest unit.
  defp age(ms) when ms < 1000, do: "#{ms}ms"
  defp age(ms) when ms < 10_000, do: "#{:erlang.float_to_binary(ms / 1000, decimals: 1)}s"
  defp age(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  defp age(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m"
  defp age(ms) when ms < 86_400_000, do: "#{div(ms, 3_600_000)}h"
  defp age(ms), do: "#{div(ms, 86_400_000)}d"

  attr :event, :map, required: true
  attr :id, :string, required: true

  def lifecycle_row(assigns) do
    ~H"""
    <li id={@id} class="grid grid-cols-[58px_48px_minmax(0,1fr)] items-baseline gap-x-2 py-[3px]">
      <span class="text-xs text-ink-dim">{String.slice(@event.at, 0, 8)}</span>
      <span class={["text-xs", event_color(@event.kind)]}>{event_word(@event.kind)}</span>
      <span class="min-w-0 truncate text-xs">
        <span class={if(@event.kind == :exit, do: "text-ink-dim", else: "text-ink/85")}>
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

  defp event_color(:spawn), do: "text-ink-dim"
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
