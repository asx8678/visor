defmodule VisorWeb.ConsoleComponents do
  @moduledoc """
  The console's entries: prompts, the work line a prompt folds into, its
  model turns and tool calls, answers and notes, with model text rendered
  as Markdown.
  """
  use VisorWeb, :html

  alias VisorWeb.ModelCall

  ## Console entries

  attr :id, :string, required: true
  attr :entry, :map, required: true

  def entry(%{entry: %{type: :user}} = assigns) do
    ~H"""
    <article id={@id} class="border-l-2 border-amber py-1 pl-3">
      <p class="whitespace-pre-wrap break-words text-[15px] font-medium text-ink">{@entry.text}</p>
    </article>
    """
  end

  # A prompt of the agent's own: background jobs ended while it was idle.
  def entry(%{entry: %{type: :wake}} = assigns) do
    ~H"""
    <article id={@id} class="border-l-2 border-rule py-1 pl-3">
      <p class="text-xs text-ink-dim">Visor, for the background jobs that ended</p>
      <p class="whitespace-pre-wrap break-words text-[13px] text-ink-dim">{@entry.text}</p>
    </article>
    """
  end

  # Everything a prompt did before its answer, folded into one line: the
  # model turns and tool calls open below it. The turn streaming now
  # shows under the line until it ends.
  def entry(%{entry: %{type: :work}} = assigns) do
    assigns = assign(assigns, :live, Enum.find(assigns.entry.steps, &Map.get(&1, :streaming)))

    ~H"""
    <article id={@id} class="text-xs">
      <details id={"#{@id}-steps"} class="group" phx-mounted={JS.ignore_attributes(["open"])}>
        <summary class="flex cursor-pointer list-none items-center gap-2 py-0.5 text-ink-dim transition-colors hover:text-ink">
          <.icon
            name="hero-chevron-right-micro"
            class="size-3.5 flex-none transition-transform group-open:rotate-90"
          />
          <span class={["lamp flex-none", work_lamp(@entry.status)]} style="--lamp-size: 7px" />
          <span class={["flex-none", work_color(@entry.status)]}>{work_headline(@entry)}</span>
          <span class={["min-w-0 truncate", @entry.status == :running && "font-mono"]}>
            {work_facts(@entry)}
          </span>
        </summary>
        <div :if={@entry.steps != []} class="mt-2 ml-1.5 space-y-3 border-l border-rule pl-4">
          <.step :for={step <- @entry.steps} :if={step != @live} :key={step.id} step={step} />
        </div>
      </details>

      <div :if={@live} class="mt-2 space-y-2">
        <p
          :if={@live.reasoning != ""}
          class="max-h-24 overflow-hidden whitespace-pre-wrap break-words text-[13px] leading-relaxed text-ink-dim"
        >
          {@live.reasoning}
        </p>
        <.markdown :if={@live.content != ""} text={@live.content} />
      </div>
    </article>
    """
  end

  def entry(%{entry: %{type: :answer}} = assigns) do
    ~H"""
    <article id={@id}>
      <.markdown text={@entry.text} />
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
        Up and down arrows recall earlier prompts. A message sent while a prompt runs
        steers it, after the running step. Escape stops a running prompt, but not the
        background jobs it started: stop those with /jobs stop or their stop button.
      </p>
      <p class="mt-2 text-ink-dim">
        Each session is logged to log/sessions. Run
        <code class="font-mono text-xs text-ink">mix visor.log</code>
        to read the latest one.
      </p>
    </div>
    """
  end

  attr :step, :map, required: true

  defp step(%{step: %{type: :turn}} = assigns) do
    ~H"""
    <div class="space-y-1.5" title={"Model turn #{@step.turn} #{@step.pid}"}>
      <details :if={@step.reasoning != ""} class="group/reasoning">
        <summary class="cursor-pointer list-none text-ink-dim hover:text-ink">
          <.icon
            name="hero-chevron-right-micro"
            class="size-3.5 transition-transform group-open/reasoning:rotate-90"
          /> Reasoning, {word_count(@step.reasoning)} words
        </summary>
        <p class="mt-1.5 whitespace-pre-wrap break-words text-[13px] leading-relaxed text-ink-dim">
          {@step.reasoning}
        </p>
      </details>
      <div :if={@step.content != ""} class="text-ink-dim">
        <.markdown text={@step.content} />
      </div>
      <p
        :if={!@step.streaming and @step.finish_reason not in ["stop", "tool_calls"]}
        class={if(ModelCall.failed?(@step.finish_reason), do: "text-alarm", else: "text-ink")}
      >
        {ModelCall.finish_text(@step.finish_reason)}
      </p>
    </div>
    """
  end

  defp step(%{step: %{type: :tool}} = assigns) do
    ~H"""
    <details id={@step.id} class="group/tool" phx-mounted={JS.ignore_attributes(["open"])}>
      <summary
        class="flex cursor-pointer list-none items-center gap-2 text-ink-dim hover:text-ink"
        title={@step.pid}
      >
        <span class={["lamp flex-none", tool_lamp(@step.status)]} style="--lamp-size: 7px" />
        <span class="min-w-0 flex-1 truncate font-mono text-ink/85">{tool_summary(@step)}</span>
        <span :if={@step.status == :running} class="live-dot flex-none text-amber">running</span>
        <span :if={@step.ms} class="flex-none">{seconds(@step.ms)}</span>
        <.icon
          name="hero-chevron-down-micro"
          class="size-3.5 flex-none transition-transform group-open/tool:rotate-180"
        />
      </summary>
      <div class="mt-1.5 border border-rule bg-well">
        <div :if={@step.code}>
          <pre class="max-h-60 overflow-auto px-3 py-2 font-mono text-xs leading-relaxed whitespace-pre-wrap break-words text-ink/90">{@step.code}</pre>
          <ol
            :if={@step.calls != []}
            class="space-y-1 border-t border-rule px-3 py-2 font-mono text-xs"
          >
            <li :for={call <- @step.calls} :key={call.n} class="flex items-center gap-2">
              <span class={["lamp", tool_lamp(call.status)]} style="--lamp-size: 7px" />
              <span class="min-w-0 flex-1 truncate text-ink/85">V.{call.text}</span>
              <span :if={call.ms} class="flex-none text-ink-dim">{seconds(call.ms)}</span>
            </li>
            <li :if={@step.call_count > length(@step.calls)} class="text-ink-dim">
              and {@step.call_count - length(@step.calls)} more calls
            </li>
          </ol>
        </div>
        <pre
          :if={@step.result}
          class={[
            "max-h-72 overflow-auto border-t border-rule px-3 py-2 font-mono text-xs leading-relaxed whitespace-pre-wrap break-words first:border-t-0",
            if(@step.status == :error, do: "text-alarm", else: "text-ink/85")
          ]}
        >{@step.result}</pre>
      </div>
    </details>
    """
  end

  ## Background jobs

  attr :id, :string, required: true
  attr :job, :map, required: true

  @doc "A background job: its id, command and how it is going or ended."
  def job_row(assigns) do
    ~H"""
    <li id={@id} class="grid grid-cols-[28px_minmax(0,1fr)_auto] items-baseline gap-x-2 py-[3px]">
      <span class="font-mono text-xs text-ink-dim">{@job.id}</span>
      <span class="min-w-0 truncate font-mono text-xs text-ink/85" title={@job.label}>
        {@job.label}
      </span>
      <span class="flex items-baseline gap-2 text-xs">
        <span class={job_color(@job.status)}>{job_state(@job)}</span>
        <button
          :if={@job.status == :running}
          id={"stop-#{@id}"}
          type="button"
          phx-click="stop_job"
          phx-value-id={@job.id}
          class="touch-manipulation text-ink-dim transition-colors hover:text-alarm"
        >
          stop
        </button>
      </span>
    </li>
    """
  end

  defp job_color(:running), do: "live-dot text-amber"
  defp job_color(:exited), do: "text-signal"
  defp job_color(:killed), do: "text-ink-dim"
  defp job_color(_failed), do: "text-alarm"

  defp job_state(%{status: :running}), do: "running"
  defp job_state(%{status: :exited, ms: ms}), do: "exit 0 · #{seconds(ms)}"

  defp job_state(%{status: :failed, exit: exit, ms: ms}) when is_integer(exit),
    do: "exit #{exit} · #{seconds(ms)}"

  defp job_state(%{status: :failed, ms: ms}), do: "failed · #{seconds(ms)}"
  defp job_state(%{status: :killed, ms: ms}), do: "stopped · #{seconds(ms)}"
  defp job_state(%{status: :timed_out, ms: ms}), do: "timed out · #{seconds(ms)}"

  def commands do
    [
      {"/stop", "Stop the running model call or tools"},
      {"/clear", "Forget the conversation and clear the console"},
      {"/compact", "Sum up the conversation so far, keeping its recent part as it was"},
      {"/jobs", "List the background jobs"},
      {"/jobs stop ID", "Stop a background job and what it started"},
      {"/jobs wake on|off", "Whether a job that ends may start the agent on its own"},
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

  # What the script did, by its first calls.
  defp tool_summary(%{name: "elixir", calls: [_ | _] = calls, call_count: count}) do
    shown = Enum.take(calls, 3)
    more = count - length(shown)
    text = Enum.map_join(shown, " · ", &("V." <> &1.text))
    if more > 0, do: "#{text} +#{more} more", else: text
  end

  defp tool_summary(%{name: "elixir", code: code}),
    do: code |> String.split("\n", parts: 2) |> hd()

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

  defp work_lamp(:running), do: "lamp-busy"
  defp work_lamp(:failed), do: "lamp-crash"
  defp work_lamp(_ended), do: "lamp-exit"

  defp work_color(:running), do: "text-ink"
  defp work_color(:failed), do: "text-alarm"
  defp work_color(_ended), do: "text-ink-dim"

  defp work_headline(%{status: :running}), do: "Working"
  defp work_headline(%{status: :done, ms: ms}), do: "Worked #{seconds(ms)}"
  defp work_headline(%{status: :stopped, ms: ms}), do: "Stopped after #{seconds(ms)}"
  defp work_headline(%{status: :failed, ms: ms}), do: "Failed after #{seconds(ms)}"

  # While running, what it is doing now; after, what it took.
  defp work_facts(%{status: :running, steps: steps}) do
    case List.last(steps) do
      %{type: :tool} = tool ->
        tool_summary(tool)

      %{type: :turn, streaming: true} = turn ->
        turn |> ModelCall.phase() |> ModelCall.phase_text()

      _ ->
        ""
    end
  end

  defp work_facts(%{totals: totals}) do
    [
      count(totals.turns, "model call"),
      totals.v_calls > 0 && count(totals.v_calls, "V call"),
      totals.prompt_tokens > 0 &&
        "#{number(totals.prompt_tokens)} in / #{number(totals.completion_tokens)} out"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp tool_lamp(:running), do: "lamp-busy"
  defp tool_lamp(:ok), do: "lamp-idle"
  defp tool_lamp(:error), do: "lamp-crash"

  defp word_count(text), do: text |> String.split() |> length()
end
