defmodule VisorWeb.HarnessComponents do
  @moduledoc """
  The panels of the harness view: runtime header, process view, console
  entries and model inspector.
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

  ## Console entries

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :tool_pids, :map, default: %{}

  def entry(%{entry: %{type: :user}} = assigns) do
    ~H"""
    <article id={@id} class="border-l-2 border-amber py-1 pl-3">
      <p class="whitespace-pre-wrap break-words text-[15px] font-medium text-ink">{@entry.text}</p>
    </article>
    """
  end

  def entry(%{entry: %{type: :turn}} = assigns) do
    ~H"""
    <article id={@id} class="space-y-2">
      <header class="flex items-center gap-2 text-xs text-ink-dim">
        <span class={["lamp", if(@entry.streaming, do: "lamp-model", else: "lamp-exit")]} />
        <span class="font-medium text-ink">Model turn {@entry.turn}</span>
        <span class="font-mono text-xs">{@entry.pid}</span>
        <span :if={@entry.streaming} class="live-dot text-sky">streaming</span>
      </header>

      <details
        :if={@entry.reasoning != ""}
        open={@entry.streaming}
        class="group border-l border-rule pl-3"
      >
        <summary class="cursor-pointer list-none text-xs text-ink-dim hover:text-ink">
          <.icon
            name="hero-chevron-right-micro"
            class="size-3.5 transition-transform group-open:rotate-90"
          /> Reasoning, {word_count(@entry.reasoning)} words
        </summary>
        <p class="mt-1.5 whitespace-pre-wrap break-words text-[13px] leading-relaxed text-ink-dim">
          {@entry.reasoning}
        </p>
      </details>

      <.markdown :if={@entry.content != ""} text={@entry.content} />

      <ul :if={@entry.streaming and @entry.tool_calls != []} class="space-y-1">
        <li :for={call <- @entry.tool_calls} class="truncate font-mono text-xs text-amber">
          {call.name} {call.arguments}
        </li>
      </ul>

      <footer
        :if={not @entry.streaming}
        class="flex flex-wrap gap-x-4 gap-y-1 text-xs text-ink-dim"
      >
        <span class={finish_color(@entry.finish_reason)}>{finish_text(@entry.finish_reason)}</span>
        <span :if={@entry.stats[:ms]}>{seconds(@entry.stats[:ms])}</span>
        <span :if={@entry.stats[:ttft_ms]}>first token {seconds(@entry.stats[:ttft_ms])}</span>
        <span :if={@entry.stats[:usage]}>
          {number(@entry.stats.usage["prompt_tokens"])} in, {number(
            @entry.stats.usage["completion_tokens"]
          )} out
        </span>
      </footer>
    </article>
    """
  end

  def entry(%{entry: %{type: :tool}} = assigns) do
    ~H"""
    <article id={@id} class="border border-rule bg-well">
      <details class="group">
        <summary class="flex cursor-pointer list-none items-center gap-2.5 px-3 py-2 text-xs phone:py-2.5">
          <span class={["lamp", tool_lamp(@entry.status)]} />
          <span class="font-medium text-ink">{@entry.name}</span>
          <span class="min-w-0 flex-1 truncate font-mono text-ink-dim">{tool_summary(@entry)}</span>
          <span :if={@entry.ms} class="flex-none text-ink-dim">{seconds(@entry.ms)}</span>
          <span :if={@entry.status == :running} class="live-dot flex-none text-amber">running</span>
          <span class="flex-none font-mono text-xs text-ink-dim phone:hidden">
            {@tool_pids[@entry.call_id]}
          </span>
          <.icon
            name="hero-chevron-down-micro"
            class="size-3.5 flex-none text-ink-dim transition-transform group-open:rotate-180"
          />
        </summary>
        <div :if={@entry.code} class="border-t border-rule">
          <pre class="max-h-60 overflow-auto px-3 py-2 font-mono text-xs leading-relaxed whitespace-pre-wrap break-words text-ink/90">{@entry.code}</pre>
          <ol
            :if={@entry.calls != []}
            class="space-y-1 border-t border-rule px-3 py-2 font-mono text-xs"
          >
            <li :for={call <- @entry.calls} class="flex items-center gap-2">
              <span class={["lamp", tool_lamp(call.status)]} style="--lamp-size: 7px" />
              <span class="min-w-0 flex-1 truncate text-ink/85">V.{call.text}</span>
              <span :if={call.ms} class="flex-none text-ink-dim">{seconds(call.ms)}</span>
            </li>
            <li :if={@entry.call_count > length(@entry.calls)} class="text-ink-dim">
              and {@entry.call_count - length(@entry.calls)} more calls
            </li>
          </ol>
        </div>
        <pre
          :if={@entry.result}
          class={[
            "max-h-72 overflow-auto border-t border-rule px-3 py-2 font-mono text-xs leading-relaxed whitespace-pre-wrap break-words",
            if(@entry.status == :error, do: "text-alarm", else: "text-ink/85")
          ]}
        >{@entry.result}</pre>
      </details>
    </article>
    """
  end

  def entry(%{entry: %{type: :note}} = assigns) do
    ~H"""
    <p
      id={@id}
      class={[
        "flex items-start gap-2 text-[13px]",
        if(@entry.level == :error, do: "text-alarm", else: "text-ink-dim")
      ]}
    >
      <.icon
        name={
          if(@entry.level == :error,
            do: "hero-exclamation-triangle-micro",
            else: "hero-information-circle-micro"
          )
        }
        class="mt-0.5 size-4 flex-none"
      />
      <span class="whitespace-pre-wrap break-words">{@entry.text}</span>
    </p>
    """
  end

  def entry(%{entry: %{type: :help}} = assigns) do
    ~H"""
    <div id={@id} class="border-l border-rule pl-3 text-[13px]">
      <p class="mb-1.5 text-ink-dim">Commands</p>
      <dl class="grid grid-cols-[auto_1fr] gap-x-5 gap-y-1">
        <%= for {command, text} <- commands() do %>
          <dt class="font-mono text-xs text-ink">{command}</dt>
          <dd class="text-ink-dim">{text}</dd>
        <% end %>
      </dl>
      <p class="mt-2 text-ink-dim">
        Anything else goes to the model. Enter sends and Shift+Enter starts a new line.
        Up and down arrows recall earlier prompts. Escape stops a running prompt.
      </p>
      <p class="mt-2 text-ink-dim">
        Each session is logged to log/sessions. Run
        <code class="font-mono text-xs text-ink">mix visor.log</code>
        to read the latest one.
      </p>
    </div>
    """
  end

  def commands do
    [
      {"/spawn [n] [seconds]", "Start n workers (default 5) that run for a while, then exit"},
      {"/crash", "Kill a random worker so its supervisor restarts it"},
      {"/stop", "Stop the running model call or tools"},
      {"/clear", "Forget the conversation and clear the console"},
      {"/effort low|high|max", "Set the reasoning effort"},
      {"/think on|off", "Turn thinking mode on or off"},
      {"/help", "Show this list"}
    ]
  end

  # Model text as Markdown. It is rendered from the tree VisorWeb.Markdown
  # parses, never as raw HTML. Inline templates stay on one line, since any
  # whitespace between inline tags would show as a space.
  attr :text, :string, required: true

  def markdown(assigns) do
    assigns = assign(assigns, :blocks, VisorWeb.Markdown.parse(assigns.text))

    ~H"""
    <div class="space-y-2.5 text-[14.5px] leading-relaxed text-ink">
      <.md_block :for={block <- @blocks} block={block} />
    </div>
    """
  end

  attr :block, :any, required: true

  defp md_block(%{block: {:code, lang, code}} = assigns) do
    assigns = assign(assigns, lang: lang, code: code)

    ~H"""
    <figure class="border border-rule bg-panel">
      <figcaption class="flex items-center justify-between border-b border-rule pl-3 text-xs text-ink-dim">
        <span class="font-mono">{if(@lang == "", do: "code", else: @lang)}</span>
        <button
          type="button"
          data-copy
          class="touch-manipulation px-3 py-1 transition-colors hover:text-ink phone:py-2"
        >
          Copy
        </button>
      </figcaption>
      <pre class="overflow-x-auto px-3 py-2 font-mono text-xs leading-relaxed text-ink/90 [font-variant-ligatures:none]"><code>{@code}</code></pre>
    </figure>
    """
  end

  defp md_block(%{block: {:heading, level, nodes}} = assigns) do
    assigns = assign(assigns, level: level, nodes: nodes)

    ~H"""
    <.dynamic_tag
      tag_name={"h#{@level + 2}"}
      class={["font-display font-semibold leading-tight text-ink", heading_size(@level)]}
    >
      <.md_inline nodes={@nodes} />
    </.dynamic_tag>
    """
  end

  defp md_block(%{block: {:paragraph, nodes}} = assigns) do
    assigns = assign(assigns, :nodes, nodes)

    ~H"""
    <p class="break-words"><.md_inline nodes={@nodes} /></p>
    """
  end

  defp md_block(%{block: {:list, items}} = assigns) do
    assigns = assign(assigns, :items, items)

    ~H"""
    <ul class="space-y-1">
      <li :for={{marker, depth, nodes} <- @items} class={["flex gap-2", indent(depth)]}>
        <span class="min-w-4 flex-none tabular-nums text-ink-dim">{marker}</span>
        <span class="min-w-0 break-words"><.md_inline nodes={nodes} /></span>
      </li>
    </ul>
    """
  end

  defp md_block(%{block: {:quote, blocks}} = assigns) do
    assigns = assign(assigns, :blocks, blocks)

    ~H"""
    <blockquote class="space-y-2 border-l-2 border-rule pl-3 text-ink-dim">
      <.md_block :for={block <- @blocks} block={block} />
    </blockquote>
    """
  end

  defp md_block(%{block: {:table, header, rows}} = assigns) do
    assigns = assign(assigns, header: header, rows: rows)

    ~H"""
    <div class="overflow-x-auto border border-rule">
      <table class="w-full text-[13px]">
        <thead :if={@header} class="bg-panel text-left text-ink-dim">
          <tr>
            <th :for={cell <- @header} class="border-b border-rule px-2.5 py-1.5 font-medium">
              <.md_inline nodes={cell} />
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} class="border-b border-rule last:border-0">
            <td :for={cell <- row} class="px-2.5 py-1.5 align-top"><.md_inline nodes={cell} /></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp md_block(%{block: :rule} = assigns) do
    ~H"""
    <hr class="border-rule" />
    """
  end

  attr :nodes, :list, required: true

  defp md_inline(assigns) do
    ~H"<.md_node :for={node <- @nodes} node={node} />"
  end

  attr :node, :any, required: true

  # Line breaks inside a paragraph are kept.
  defp md_node(%{node: text} = assigns) when is_binary(text) do
    case String.split(text, "\n") do
      [line] ->
        assigns = assign(assigns, :line, line)
        ~H"{@line}"

      lines ->
        assigns = assign(assigns, :nodes, Enum.intersperse(lines, :break))
        ~H"<.md_inline nodes={@nodes} />"
    end
  end

  defp md_node(%{node: :break} = assigns), do: ~H"<br />"

  defp md_node(%{node: {:code, code}} = assigns) do
    assigns = assign(assigns, :code, code)

    ~H|<code class="bg-ink/8 px-1 py-px font-mono text-[0.86em] text-ink [font-variant-ligatures:none]">{@code}</code>|
  end

  defp md_node(%{node: {:strong, nodes}} = assigns) do
    assigns = assign(assigns, :nodes, nodes)
    ~H|<strong class="font-semibold"><.md_inline nodes={@nodes} /></strong>|
  end

  defp md_node(%{node: {:em, nodes}} = assigns) do
    assigns = assign(assigns, :nodes, nodes)
    ~H|<em><.md_inline nodes={@nodes} /></em>|
  end

  defp md_node(%{node: {:link, url, nodes}} = assigns) do
    assigns = assign(assigns, url: url, nodes: nodes)

    ~H|<a
  href={@url}
  target="_blank"
  rel="noopener noreferrer"
  class="text-sky underline decoration-sky/40 underline-offset-2 hover:decoration-sky"
><.md_inline nodes={@nodes} /></a>|
  end

  defp heading_size(1), do: "text-xl"
  defp heading_size(2), do: "text-lg"
  defp heading_size(3), do: "text-base"

  defp indent(0), do: nil
  defp indent(1), do: "pl-5"
  defp indent(2), do: "pl-10"
  defp indent(3), do: "pl-15"

  defp tool_summary(%{name: "elixir", status: :running, calls: [_ | _] = calls}),
    do: "V." <> List.last(calls).text

  defp tool_summary(%{name: "elixir", call_count: count}) when count > 0,
    do: "#{count} #{if count == 1, do: "call", else: "calls"} in one process"

  defp tool_summary(%{name: "elixir", code: code}),
    do: code |> String.split("\n", parts: 2) |> hd()

  defp tool_summary(%{name: "bash", arguments: arguments}) do
    case Jason.decode(arguments) do
      {:ok, %{"command" => command}} -> "$ " <> command
      _ -> arguments
    end
  end

  defp tool_summary(%{arguments: arguments}) do
    case Jason.decode(arguments) do
      {:ok, args} when map_size(args) == 0 ->
        ""

      {:ok, args} when is_map(args) ->
        Enum.map_join(args, " ", fn {k, v} -> "#{k}: #{inspect(v)}" end)

      _ ->
        arguments
    end
  end

  defp tool_lamp(:running), do: "lamp-busy"
  defp tool_lamp(:ok), do: "lamp-idle"
  defp tool_lamp(:error), do: "lamp-crash"

  defp finish_text("stop"), do: "finished"
  defp finish_text("tool_calls"), do: "called tools"
  defp finish_text("length"), do: "cut off at max tokens"
  defp finish_text("interrupted"), do: "stopped"
  defp finish_text("crashed"), do: "crashed"
  defp finish_text("error"), do: "failed"
  defp finish_text(other), do: other || "ended"

  defp finish_color(reason) when reason in ["stop", "tool_calls"], do: "text-ink-dim"
  defp finish_color("interrupted"), do: "text-ink"
  defp finish_color(_reason), do: "text-alarm"

  ## Phone tab bar

  attr :status, :atom, required: true
  attr :process_count, :integer, required: true
  attr :key, :atom, required: true

  def panel_tabs(assigns) do
    ~H"""
    <nav
      id="panel-tabs"
      class="visor-tabs grid grid-cols-3 border-t border-rule bg-panel"
      aria-label="Panels"
    >
      <.panel_tab tab="console" label="Console" lamp={status_lamp(@status)} selected />
      <.panel_tab tab="processes" label="Processes" lamp="lamp-supervisor" count={@process_count} />
      <.panel_tab
        tab="model"
        label="Model"
        lamp={if(@key == :none, do: "lamp-exit", else: "lamp-idle")}
      />
    </nav>
    """
  end

  attr :tab, :string, required: true
  attr :label, :string, required: true
  attr :lamp, :string, required: true
  attr :count, :integer, default: nil
  attr :selected, :boolean, default: false

  defp panel_tab(assigns) do
    ~H"""
    <button
      type="button"
      id={"tab-#{@tab}"}
      aria-pressed={to_string(@selected)}
      phx-click={
        JS.set_attribute({"data-tab", @tab}, to: "#visor-shell")
        |> JS.set_attribute({"aria-pressed", "false"}, to: "#panel-tabs button")
        |> JS.set_attribute({"aria-pressed", "true"})
      }
      class="flex h-14 touch-manipulation items-center justify-center gap-2 text-sm text-ink-dim transition-colors aria-pressed:bg-well aria-pressed:text-ink aria-pressed:shadow-[inset_0_2px_0_var(--color-amber)]"
    >
      <span class={["lamp", @lamp]} />
      {@label}
      <span :if={@count} class="text-xs text-ink-dim">{@count}</span>
    </button>
    """
  end

  ## Model inspector

  attr :status, :atom, required: true
  attr :tools_running, :integer, required: true

  def status_readout(assigns) do
    ~H"""
    <div id="agent-status" class="flex items-center gap-3">
      <span class={["lamp [--lamp-size:12px]", status_lamp(@status)]} />
      <span class="font-display text-[28px] font-medium leading-none text-ink">
        {status_text(@status, @tools_running)}
      </span>
    </div>
    """
  end

  defp status_lamp(:idle), do: "lamp-idle"
  defp status_lamp(:streaming), do: "lamp-model"
  defp status_lamp(:tools), do: "lamp-busy"

  defp status_text(:idle, _), do: "Idle"
  defp status_text(:streaming, _), do: "Streaming"
  defp status_text(:tools, 1), do: "Running a tool"
  defp status_text(:tools, n), do: "Running #{n} tools"

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true
  attr :selected, :string, required: true
  attr :event, :string, required: true
  attr :key, :string, required: true

  def segmented(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3">
      <span class="text-[13px] text-ink-dim">{@label}</span>
      <div id={@id} class="flex border border-rule" role="group" aria-label={@label}>
        <button
          :for={option <- @options}
          type="button"
          id={"#{@id}-#{option}"}
          phx-click={@event}
          phx-value-key={@key}
          phx-value-value={option}
          aria-pressed={to_string(option == @selected)}
          class={[
            "touch-manipulation px-2.5 py-1 text-xs transition-colors phone:px-3.5 phone:py-2",
            if(option == @selected,
              do: "bg-amber font-semibold text-rack",
              else: "text-ink-dim hover:bg-well hover:text-ink"
            )
          ]}
        >
          {option}
        </button>
      </div>
    </div>
    """
  end

  # Rows are {label, value}, or {label, value, :wide} for a value that needs
  # both columns.
  attr :rows, :list, required: true

  def readings(assigns) do
    ~H"""
    <dl class="grid grid-cols-2 gap-x-4 gap-y-2.5">
      <div :for={row <- @rows} class={["min-w-0", tuple_size(row) == 3 && "col-span-2"]}>
        <dt class="text-xs text-ink-dim">{elem(row, 0)}</dt>
        <dd class="font-display text-[17px] font-medium leading-tight break-words text-ink">
          {elem(row, 1)}
        </dd>
      </div>
    </dl>
    """
  end

  # How much of the context window the conversation fills: the last
  # turn's prompt and reply, which the next request sends again.
  attr :tokens, :integer, default: nil
  attr :window, :integer, default: nil
  attr :messages, :integer, required: true

  def context_meter(assigns) do
    share =
      if assigns.tokens && assigns.window,
        do: min(assigns.tokens * 100 / assigns.window, 100.0)

    assigns = assign(assigns, :share, share)

    ~H"""
    <div id="context-meter">
      <div class="flex justify-between text-xs text-ink-dim">
        <span>Context</span>
        <span>{@messages} {if(@messages == 1, do: "message", else: "messages")}</span>
      </div>
      <div :if={@share} class="mt-1 h-1.5 bg-well">
        <div
          class={["h-full transition-[width] duration-300", context_color(@share)]}
          style={"width: #{if(@share > 0, do: max(@share, 0.5), else: 0)}%"}
        />
      </div>
      <p class="mt-1 font-display text-[17px] font-medium leading-tight text-ink">
        {context_text(@tokens, @window)}
      </p>
    </div>
    """
  end

  defp context_color(share) when share >= 90, do: "bg-alarm"
  defp context_color(share) when share >= 70, do: "bg-amber"
  defp context_color(_share), do: "bg-ink-dim"

  defp context_text(nil, nil), do: "No model turn yet"
  defp context_text(nil, window), do: "#{number(window)} token window"
  defp context_text(tokens, nil), do: "#{number(tokens)} tokens"
  defp context_text(tokens, window), do: "#{number(tokens)} of #{number(window)} tokens"

  attr :hit, :integer, required: true
  attr :miss, :integer, required: true

  def cache_bar(assigns) do
    total = assigns.hit + assigns.miss

    assigns =
      assign(assigns, :share, if(total > 0, do: round(assigns.hit * 100 / total), else: 0))

    ~H"""
    <div>
      <div class="flex justify-between text-xs text-ink-dim">
        <span>Prompt cache</span>
        <span>{@share}% hit</span>
      </div>
      <div class="mt-1 h-1.5 bg-well">
        <div class="h-full bg-ink-dim transition-[width] duration-300" style={"width: #{@share}%"} />
      </div>
    </div>
    """
  end

  ## Formatting

  def dom_safe(text), do: String.replace(text, ~r/[^A-Za-z0-9_-]/, "-")

  # With its angle brackets, so it reads as a PID and not a version.
  def pid_text(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  def pid_text(_), do: nil

  def number(nil), do: "–"

  def number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def seconds(nil), do: "–"
  def seconds(ms) when ms < 1000, do: "#{ms} ms"
  def seconds(ms), do: "#{:erlang.float_to_binary(ms / 1000, decimals: 1)} s"

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

  defp word_count(text), do: text |> String.split() |> length()
end
