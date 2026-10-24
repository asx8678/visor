defmodule VisorWeb.InspectorComponents do
  @moduledoc """
  The model inspector (status, settings, the running prompt's budget,
  context, the model calls and the session's totals) and the tab bar that
  switches panels on a phone.
  """
  use VisorWeb, :html

  alias VisorWeb.ModelCall

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
  attr :live_turn, :map, default: nil

  def status_readout(assigns) do
    ~H"""
    <div id="agent-status" class="flex items-center gap-2">
      <span class={["lamp", status_lamp(@status)]} />
      <span class={["text-[13px]", if(@status == :idle, do: "text-ink-dim", else: "text-ink")]}>
        {status_text(@status, @tools_running, @live_turn)}
      </span>
    </div>
    """
  end

  defp status_lamp(:idle), do: "lamp-idle"
  defp status_lamp(:streaming), do: "lamp-model"
  defp status_lamp(:tools), do: "lamp-busy"

  defp status_text(:idle, _, _), do: "Idle"

  defp status_text(:streaming, _, turn) do
    case turn && ModelCall.phase(turn) do
      :thinking -> "Thinking"
      :reply -> "Writing"
      :tool_call -> "Writing a tool call"
      _waiting -> "Waiting"
    end
  end

  defp status_text(:tools, 1, _), do: "Running a tool"
  defp status_text(:tools, n, _), do: "Running #{n} tools"

  # The running prompt's place in its budget of model calls. The bar turns
  # amber once the agent is told its calls are running out.
  attr :step, :map, required: true
  attr :ms, :integer, required: true

  def step_meter(assigns) do
    assigns = assign(assigns, :late, assigns.step.max - assigns.step.n < 4)

    ~H"""
    <div id="agent-progress" class="space-y-1">
      <div class="flex justify-between text-xs text-ink-dim tabular-nums">
        <span>Model call {@step.n} of {@step.max}</span>
        <span>{clock(@ms)}</span>
      </div>
      <div class="flex h-1 gap-px">
        <span
          :for={n <- 1..@step.max}
          class={[
            "flex-1",
            cond do
              n > @step.n -> "bg-well"
              @late -> "bg-amber"
              true -> "bg-ink-dim"
            end
          ]}
        />
      </div>
    </div>
    """
  end

  defp clock(ms) when ms < 60_000, do: "#{div(ms, 1000)} s"
  defp clock(ms), do: "#{div(ms, 60_000)} min #{rem(div(ms, 1000), 60)} s"

  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :aside, :any, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def inspector_section(assigns) do
    ~H"""
    <section id={@id} class={["space-y-2 border-t border-rule px-4 py-3", @class]}>
      <h3 class="flex items-baseline justify-between gap-3 text-xs text-ink-dim">
        <span>{@title}</span>
        <span :if={@aside} class="min-w-0 truncate tabular-nums">{@aside}</span>
      </h3>
      {render_slot(@inner_block)}
    </section>
    """
  end

  # A section that stays closed until it is wanted.
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :aside, :any, default: nil
  slot :inner_block, required: true

  def fold(assigns) do
    ~H"""
    <section id={@id} class="border-t border-rule px-4 py-2.5">
      <details
        id={"#{@id}-fold"}
        class="group/fold"
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <summary class="flex cursor-pointer list-none items-center gap-1 text-xs text-ink-dim hover:text-ink">
          <.icon
            name="hero-chevron-right-micro"
            class="size-3.5 flex-none transition-transform group-open/fold:rotate-90"
          />
          <span class="flex-1">{@title}</span>
          <span :if={@aside} class="min-w-0 truncate">{@aside}</span>
        </summary>
        <div class="mt-2">{render_slot(@inner_block)}</div>
      </details>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true
  attr :selected, :string, required: true
  attr :event, :string, required: true
  attr :key, :string, required: true
  attr :class, :any, default: nil

  def segmented(assigns) do
    ~H"""
    <div class={["flex items-center gap-2", @class]}>
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
            "touch-manipulation px-2 py-0.5 text-xs transition-colors phone:px-3.5 phone:py-2",
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

  # Label and value on one line, in one or two columns. Rows are {label,
  # value}, or {label, value, :alarm} for a value that reports a failure.
  attr :id, :string, default: nil
  attr :rows, :list, required: true
  attr :cols, :integer, default: 1

  def readings(assigns) do
    ~H"""
    <dl id={@id} class={["grid gap-x-5 gap-y-1 text-[13px]", @cols == 2 && "grid-cols-2"]}>
      <div :for={row <- @rows} class="flex min-w-0 items-baseline justify-between gap-2">
        <dt class="flex-none text-ink-dim">{elem(row, 0)}</dt>
        <dd
          class={[
            "min-w-0 truncate text-right tabular-nums",
            if(tuple_size(row) == 3, do: "text-alarm", else: "text-ink")
          ]}
          title={elem(row, 1)}
        >
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

  def context_meter(assigns) do
    share =
      if assigns.tokens && assigns.window,
        do: min(assigns.tokens * 100 / assigns.window, 100.0)

    assigns = assign(assigns, :share, share)

    ~H"""
    <div
      id="context-meter"
      class="h-1.5 bg-well"
      title={@tokens && "#{number(@tokens)} tokens#{@window && " of #{number(@window)}"}"}
    >
      <div
        :if={@share}
        class={["h-full transition-[width] duration-300", context_color(@share)]}
        style={"width: #{if(@share > 0, do: max(@share, 0.5), else: 0)}%"}
      />
    </div>
    """
  end

  defp context_color(share) when share >= 90, do: "bg-alarm"
  defp context_color(share) when share >= 70, do: "bg-amber"
  defp context_color(_share), do: "bg-ink-dim"

  attr :hit, :integer, required: true
  attr :miss, :integer, required: true
  attr :unmeasured, :integer, default: 0

  # Until a call reports its cache use there is nothing to measure, so no
  # share rather than 0%.
  def cache_bar(assigns) do
    total = assigns.hit + assigns.miss

    assigns =
      assign(assigns,
        share: if(total > 0, do: round(assigns.hit * 100 / total)),
        total: total
      )

    ~H"""
    <div
      id="cache-bar"
      class="flex items-center gap-3 text-[13px]"
      title={
        cond do
          @share && @unmeasured > 0 ->
            "#{number(@hit)} of #{number(@total)} measured prompt tokens came from the cache; " <>
              "#{number(@unmeasured)} more had no cache figures"

          @share ->
            "#{number(@hit)} of #{number(@total)} prompt tokens came from the cache"

          @unmeasured > 0 ->
            "The provider reported no cache figures for #{number(@unmeasured)} prompt tokens"

          true ->
            "No cache figures yet"
        end
      }
    >
      <span class="flex-none text-ink-dim">Prompt cache</span>
      <div class="h-1.5 flex-1 bg-well">
        <div
          class="h-full bg-ink-dim transition-[width] duration-300"
          style={"width: #{@share || 0}%"}
        />
      </div>
      <span :if={@share} class="flex-none text-ink tabular-nums">{@share}%</span>
      <span :if={@share && @unmeasured > 0} class="flex-none text-ink-dim">of measured</span>
      <span :if={!@share && @unmeasured > 0} class="flex-none text-ink-dim">unknown</span>
      <span :if={!@share && @unmeasured == 0} class="flex-none text-ink-dim">–</span>
    </div>
    """
  end

  # The session's model calls, newest first: how long each took, against
  # the longest shown, its tokens and how it ended.
  attr :turns, :list, required: true
  attr :live, :map, default: nil
  attr :now, :integer, required: true

  def turn_history(assigns) do
    longest = assigns.turns |> Enum.map(&(&1.ms || 0)) |> Enum.max(fn -> 0 end) |> max(1)
    assigns = assign(assigns, :longest, longest)

    ~H"""
    <ol id="turn-history" class="space-y-0.5 text-xs tabular-nums">
      <li
        :if={@live}
        class="grid grid-cols-[2.25rem_1fr_3.25rem_3.5rem_3rem] items-center gap-2"
        title={"Model call #{@live.turn}: running, #{count(@live.chunks, "chunk")} so far"}
      >
        <span class="text-ink">#{@live.turn}</span>
        <span class="live-dot h-1 bg-sky" />
        <span class="text-right text-ink">{div(max(@now - @live.started, 0), 1000)} s</span>
        <span class="text-right text-ink-dim">–</span>
        <span class="text-right text-ink-dim">–</span>
      </li>
      <li
        :for={turn <- @turns}
        class="grid grid-cols-[2.25rem_1fr_3.25rem_3.5rem_3rem] items-center gap-2"
        title={turn_title(turn)}
      >
        <span class="text-ink-dim">#{turn.turn}</span>
        <span class="h-1 bg-well">
          <span
            class={["block h-full", if(turn_failed?(turn), do: "bg-alarm", else: "bg-ink-dim")]}
            style={"width: #{max((turn.ms || 0) * 100 / @longest, 1)}%"}
          />
        </span>
        <span class="text-right text-ink">{seconds(turn.ms)}</span>
        <span class="text-right text-ink-dim">{short(turn.prompt)}</span>
        <span class={["text-right", if(turn_failed?(turn), do: "text-alarm", else: "text-ink-dim")]}>
          {short(turn.completion)}
        </span>
      </li>
      <li :if={@turns == [] and !@live} class="text-ink-dim">No model calls yet.</li>
    </ol>
    """
  end

  defp turn_failed?(turn), do: ModelCall.failed?(turn.finish)

  defp turn_title(turn) do
    "Model call #{turn.turn}: #{seconds(turn.ms)}, first token after #{seconds(turn.ttft_ms)}, " <>
      "#{number(turn.prompt)} tokens in (#{number(turn.cached)} cached), " <>
      "#{number(turn.completion)} out, #{ModelCall.finish_text(turn.finish)}"
  end
end
