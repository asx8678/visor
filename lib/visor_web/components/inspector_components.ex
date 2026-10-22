defmodule VisorWeb.InspectorComponents do
  @moduledoc """
  The model inspector (status, settings, readings, context and cache) and
  the tab bar that switches panels on a phone.
  """
  use VisorWeb, :html

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
end
