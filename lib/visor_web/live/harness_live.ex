defmodule VisorWeb.HarnessLive do
  @moduledoc """
  The harness view: the live supervision tree on the left, the agent
  console in the middle and the model inspector on the right.

  Each connected view starts its own session (a supervisor with an agent
  and a task supervisor) under `Visor.Harness`, so it shows up in the tree.
  """
  use VisorWeb, :live_view

  import VisorWeb.HarnessComponents

  alias Visor.{Agent, Harness, Model, Observer}

  @log_limit 150
  @empty_snapshot %{tree: [], lamps: [], stats: %{}, apps: [], history: []}
  @empty_totals %{turns: 0, prompt: 0, completion: 0, cache_hit: 0, cache_miss: 0, reasoning: 0}

  @examples [
    "List the files in this project",
    "Read mix.exs",
    "Search for Supervisor",
    "$ ls lib/visor",
    "Count functions in each file",
    "Show BEAM stats"
  ]

  # A script's calls shown under its tool card; later ones are only counted.
  @shown_calls 100

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Harness",
        client_layout: session["layout"] || "desktop",
        session_id: nil,
        snapshot: Observer.snapshot() || @empty_snapshot,
        provider: Model.current().info(),
        status: :idle,
        settings: %{effort: "high", thinking: true},
        live_turn: nil,
        turn_stats: nil,
        totals: @empty_totals,
        context_messages: 0,
        context_tokens: nil,
        last_request: nil,
        tool_pids: %{},
        tools_running: 0,
        code_runs: %{},
        examples: @examples,
        form: to_form(%{"text" => ""}, as: :prompt)
      )
      |> stream(:entries, [])
      |> stream(:events, [])

    if connected?(socket) do
      Observer.subscribe()
      {:ok, id} = Harness.start_session(self())
      Agent.subscribe(id)
      settings = Agent.settings(id)

      {:ok,
       assign(socket,
         session_id: id,
         settings: Map.take(settings, [:effort, :thinking]),
         provider: settings.provider
       )}
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} layout={@client_layout}>
      <.runtime_header stats={@snapshot.stats} history={@snapshot.history} provider={@provider} />

      <section
        id="processes"
        class="visor-processes flex min-h-0 flex-col border-r border-rule bg-panel"
        aria-label="Processes"
      >
        <div class="space-y-3 border-b border-rule px-4 py-3">
          <div class="flex items-center justify-between gap-3">
            <h2 class="font-display text-lg font-medium text-ink">Processes</h2>
            <div class="flex gap-1.5">
              <button
                id="spawn-workers"
                type="button"
                phx-click="spawn"
                class="touch-manipulation border border-rule px-2.5 py-1 text-xs text-ink transition-colors hover:border-signal hover:text-signal phone:px-3 phone:py-2 phone:text-[13px]"
              >
                Spawn workers
              </button>
              <button
                id="crash-worker"
                type="button"
                phx-click="crash"
                class="touch-manipulation border border-rule px-2.5 py-1 text-xs text-ink transition-colors hover:border-alarm hover:text-alarm phone:px-3 phone:py-2 phone:text-[13px]"
              >
                Crash a worker
              </button>
            </div>
          </div>
          <.app_strip apps={@snapshot.apps} />
          <.lamp_field lamps={@snapshot.lamps} />
        </div>

        <div class="min-h-0 flex-1 overflow-y-auto px-3 py-2">
          <.supervision_tree tree={@snapshot.tree} />
        </div>

        <div class="flex h-[34%] min-h-40 flex-col border-t border-rule">
          <h3 class="px-4 pt-2.5 pb-1 text-xs text-ink-dim">Lifecycle</h3>
          <div
            id="lifecycle-scroll"
            phx-hook=".AutoScroll"
            class="min-h-0 flex-1 overflow-y-auto px-4 pb-2"
          >
            <ol id="lifecycle" phx-update="stream">
              <li id="lifecycle-empty" class="hidden text-xs text-ink-dim only:block">
                Spawns, exits and crashes in the harness appear here as they happen.
              </li>
              <.lifecycle_row :for={{id, event} <- @streams.events} id={id} event={event} />
            </ol>
          </div>
        </div>
      </section>

      <section id="console" class="visor-console flex min-h-0 flex-col" aria-label="Console">
        <div class="console-bar flex items-center gap-3 border-b border-rule px-5 py-3 phone:px-4 phone:py-2.5">
          <h2 class="font-display text-lg font-medium text-ink">Console</h2>
          <span :if={@session_id} id="session-id" class="text-xs text-ink-dim">
            session {@session_id}
          </span>
          <button
            id="clear-console"
            type="button"
            phx-click="clear"
            class="-my-2 ml-auto touch-manipulation px-2 py-2 text-xs text-ink-dim transition-colors hover:text-ink"
          >
            Clear
          </button>
        </div>

        <div id="console-scroll" phx-hook=".AutoScroll" class="min-h-0 flex-1 overflow-y-auto">
          <div
            id="entries"
            phx-update="stream"
            phx-hook=".CopyCode"
            class="mx-auto max-w-3xl space-y-5 px-5 py-6 phone:px-4 phone:py-5"
          >
            <div id="console-empty" class="hidden only:block">
              <p class="font-display text-2xl font-medium text-ink">
                Every model call and tool call runs in its own process.
              </p>
              <p class="mt-2 max-w-xl text-sm text-ink-dim">
                Send a prompt and watch them start, work and exit in the process tree.
                Type /help for commands.
              </p>
              <ul class="mt-5 flex flex-wrap gap-2">
                <li :for={example <- @examples}>
                  <button
                    type="button"
                    phx-click="example"
                    phx-value-text={example}
                    class="touch-manipulation border border-rule bg-panel px-3 py-1.5 text-[13px] text-ink transition-colors hover:border-amber hover:text-amber phone:py-2"
                  >
                    {example}
                  </button>
                </li>
              </ul>
            </div>
            <.entry
              :for={{id, entry} <- @streams.entries}
              id={id}
              entry={entry}
              tool_pids={@tool_pids}
            />
          </div>
        </div>

        <.form
          for={@form}
          id="prompt-form"
          phx-submit="submit"
          class="border-t border-rule bg-panel px-5 py-3 phone:px-3 phone:py-2.5"
        >
          <div class="mx-auto flex max-w-3xl items-end gap-3 border border-rule bg-well pr-1.5 pl-3 transition-colors focus-within:border-amber">
            <span
              class="self-start py-2.5 font-mono leading-6 text-amber phone:py-3"
              aria-hidden="true"
            >
              &gt;
            </span>
            <div class="min-w-0 flex-1 [&_.fieldset]:m-0 [&_.fieldset]:p-0">
              <.input
                field={@form[:text]}
                id="prompt-input"
                type="textarea"
                rows="1"
                phx-hook=".CommandLine"
                autocomplete="off"
                aria-label="Prompt or command"
                placeholder={placeholder(@status)}
                enterkeyhint="send"
                class="block max-h-[40vh] w-full resize-none bg-transparent py-2.5 text-base leading-6 text-ink placeholder:text-ink-dim/70 focus:outline-none focus-visible:outline-none phone:py-3"
              />
            </div>
            <button
              :if={@status == :idle}
              id="send-prompt"
              type="submit"
              class="mb-1.5 touch-manipulation bg-amber px-3.5 py-1.5 text-sm font-semibold text-rack transition hover:brightness-110 phone:px-4 phone:py-2"
            >
              Send
            </button>
            <button
              :if={@status != :idle}
              id="stop-agent"
              type="button"
              phx-click="interrupt"
              class="mb-1.5 touch-manipulation border border-alarm px-3.5 py-1.5 text-sm font-semibold text-alarm transition-colors hover:bg-alarm hover:text-rack phone:px-4 phone:py-2"
            >
              Stop
            </button>
          </div>
        </.form>
      </section>

      <aside
        id="model-inspector"
        class="visor-model min-h-0 space-y-6 overflow-y-auto border-l border-rule bg-panel px-4 py-4"
        aria-label="Model"
      >
        <div class="space-y-3">
          <h2 class="font-display text-lg font-medium text-ink">Model</h2>
          <.status_readout status={@status} tools_running={@tools_running} />
          <.readings rows={[
            {"Provider", @provider.provider},
            {"API key", key_text(@provider.key)},
            {"Model", @provider.model, :wide},
            {"Endpoint", endpoint_text(@provider[:endpoint]), :wide},
            {"Max output", max_tokens_text(@provider[:max_tokens])}
          ]} />
          <.context_meter
            tokens={@context_tokens}
            window={@provider[:context_window]}
            messages={@context_messages}
          />
        </div>

        <div class="space-y-2.5 border-t border-rule pt-4">
          <.segmented
            id="thinking-mode"
            label="Thinking"
            options={["on", "off"]}
            selected={if(@settings.thinking, do: "on", else: "off")}
            event="configure"
            key="thinking"
          />
          <div class={[not @settings.thinking && "opacity-50"]}>
            <.segmented
              id="reasoning-effort"
              label="Reasoning effort"
              options={Agent.efforts()}
              selected={@settings.effort}
              event="configure"
              key="effort"
            />
          </div>
        </div>

        <div id="turn-readings" class="space-y-3 border-t border-rule pt-4">
          <h3 class="text-[13px] text-ink-dim">
            {if(@turn_stats, do: "Model turn #{@turn_stats.turn}", else: "No model turn yet")}
          </h3>
          <.readings :if={@turn_stats} rows={turn_rows(@turn_stats)} />
        </div>

        <div id="session-readings" class="space-y-3 border-t border-rule pt-4">
          <h3 class="text-[13px] text-ink-dim">This session</h3>
          <.readings rows={[
            {"Model turns", number(@totals.turns)},
            {"Reasoning tokens", number(@totals.reasoning)},
            {"Tokens in", number(@totals.prompt)},
            {"Tokens out", number(@totals.completion)}
          ]} />
          <.cache_bar hit={@totals.cache_hit} miss={@totals.cache_miss} />
        </div>

        <div id="last-request" class="space-y-2 border-t border-rule pt-4">
          <h3 class="text-[13px] text-ink-dim">
            {if(@last_request, do: "Request for turn #{@last_request.turn}", else: "Last request")}
          </h3>
          <pre
            :if={@last_request}
            class="max-h-96 overflow-auto bg-well p-2.5 font-mono text-xs leading-relaxed whitespace-pre-wrap break-words text-ink/80"
          >{@last_request.json}</pre>
          <p :if={!@last_request} class="text-xs text-ink-dim">
            The request body appears here when the agent calls the model.
          </p>
        </div>
      </aside>

      <.panel_tabs
        status={@status}
        process_count={length(@snapshot.tree)}
        key={@provider.key}
      />

      <div id="client-layout" phx-hook=".ClientLayout" hidden></div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ClientLayout">
        // Picks the layout from the device. Touch screens whose short side is
        // under 600px are phones either way up; narrow windows get the phone
        // layout too. Applied at once, then reported so the server agrees.
        // After a reconnect the server is back to its user-agent guess, so
        // the layout is reported again.
        const pick = () => {
          const touch = matchMedia("(pointer: coarse)").matches
          if (innerWidth < 768 || (touch && Math.min(innerWidth, innerHeight) < 600)) return "phone"
          return innerWidth < 1180 ? "tablet" : "desktop"
        }

        export default {
          mounted() {
            const shell = document.getElementById("visor-shell")
            this.sent = shell.dataset.layout
            this.apply = () => {
              const layout = pick()
              shell.dataset.layout = layout
              if (layout !== this.sent) {
                this.sent = layout
                this.pushEvent("client_layout", {layout})
              }
            }
            this.onResize = () => {
              cancelAnimationFrame(this.frame)
              this.frame = requestAnimationFrame(this.apply)
            }
            window.addEventListener("resize", this.onResize)
            this.apply()
          },
          reconnected() {
            this.sent = null
            this.apply()
          },
          destroyed() {
            window.removeEventListener("resize", this.onResize)
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoScroll">
        // Keeps a log pinned to the bottom unless the reader has scrolled up.
        export default {
          mounted() {
            this.pinned = true
            this.el.addEventListener("scroll", () => {
              this.pinned = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 48
            })
            this.observer = new MutationObserver(() => {
              if (this.pinned) this.el.scrollTop = this.el.scrollHeight
            })
            this.observer.observe(this.el, {childList: true, subtree: true, characterData: true})
            // On phones the panel is hidden while another tab is open;
            // catch up when it is shown again.
            this.resized = new ResizeObserver(() => {
              if (this.pinned) this.el.scrollTop = this.el.scrollHeight
            })
            this.resized.observe(this.el)
            this.el.scrollTop = this.el.scrollHeight
          },
          destroyed() {
            this.observer.disconnect()
            this.resized.disconnect()
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CommandLine">
        // Enter sends and Shift+Enter starts a new line; the box grows with
        // the text. Up and Down recall earlier prompts from the first and last
        // line, and Escape stops a running prompt. The box is cleared once
        // LiveView has read it, so the next prompt can be typed straight away.
        export default {
          mounted() {
            this.history = []
            this.index = 0
            this.el.addEventListener("input", () => this.fit())
            this.el.form.addEventListener("submit", () => {
              const text = this.el.value.trim()
              if (text && this.history[this.history.length - 1] !== text) this.history.push(text)
              this.index = this.history.length
              setTimeout(() => this.recall(this.index))
            })
            this.el.addEventListener("keydown", e => {
              const {value, selectionStart, selectionEnd} = this.el
              if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                e.preventDefault()
                this.el.form.requestSubmit()
              } else if (e.key === "ArrowUp" && this.index > 0 &&
                         !value.slice(0, selectionStart).includes("\n")) {
                e.preventDefault()
                this.recall(this.index - 1)
              } else if (e.key === "ArrowDown" && this.index < this.history.length &&
                         !value.slice(selectionEnd).includes("\n")) {
                e.preventDefault()
                this.recall(this.index + 1)
              } else if (e.key === "Escape") {
                this.pushEvent("interrupt", {})
              }
            })
            // Focus on desktop only; on phones it would open the keyboard.
            if (matchMedia("(pointer: fine)").matches) this.el.focus()
          },
          recall(index) {
            this.index = index
            this.el.value = this.history[index] ?? ""
            this.fit()
          },
          fit() {
            this.el.style.height = "auto"
            this.el.style.height = `${this.el.scrollHeight}px`
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyCode">
        // Copy buttons on the code blocks in model replies.
        export default {
          mounted() {
            this.el.addEventListener("click", e => {
              const button = e.target.closest("[data-copy]")
              const code = button?.closest("figure").querySelector("pre")
              if (!code) return
              const copied = () => {
                button.textContent = "Copied"
                setTimeout(() => { button.textContent = "Copy" }, 1500)
              }
              // Without a secure origin there is no clipboard; select the code
              // so it can be copied by hand.
              if (navigator.clipboard) {
                navigator.clipboard.writeText(code.innerText).then(copied)
              } else {
                getSelection().selectAllChildren(code)
              }
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  ## Events from the page

  @impl true
  def handle_event("submit", %{"prompt" => %{"text" => text}}, socket) do
    {:noreply, send_input(socket, String.trim(text))}
  end

  def handle_event("example", %{"text" => text}, socket) do
    {:noreply, send_input(socket, text)}
  end

  def handle_event("client_layout", %{"layout" => layout}, socket) do
    if layout in VisorWeb.ClientLayout.layouts() do
      {:noreply, assign(socket, :client_layout, layout)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("interrupt", _params, socket) do
    _ = Agent.interrupt(socket.assigns.session_id)
    {:noreply, socket}
  end

  def handle_event("clear", _params, socket), do: {:noreply, run_command(socket, "clear", [])}

  def handle_event("spawn", _params, socket) do
    Harness.spawn_workers(5, 8_000)
    {:noreply, socket}
  end

  def handle_event("crash", _params, socket), do: {:noreply, run_command(socket, "crash", [])}

  def handle_event("configure", %{"key" => "effort", "value" => effort}, socket) do
    {:noreply, configure(socket, effort: effort)}
  end

  def handle_event("configure", %{"key" => "thinking", "value" => value}, socket) do
    {:noreply, configure(socket, thinking: value == "on")}
  end

  defp send_input(socket, ""), do: socket

  defp send_input(socket, "/" <> command_line) do
    {command, args} =
      case String.split(command_line) do
        [command | args] -> {command, args}
        [] -> {"help", []}
      end

    run_command(socket, command, args)
  end

  defp send_input(socket, text) do
    case Agent.prompt(socket.assigns.session_id, text) do
      :ok ->
        socket

      {:error, :busy} ->
        note(socket, :info, "The agent is still working. Wait for it to finish, or press Stop.")
    end
  end

  ## Slash commands

  defp run_command(socket, "help", _args), do: add_entry(socket, %{type: :help})

  defp run_command(socket, "spawn", args) do
    count = int_arg(args, 0, 5, 1..50)
    seconds = int_arg(args, 1, 8, 1..120)
    Harness.spawn_workers(count, seconds * 1000)

    note(
      socket,
      :info,
      "Started #{count} workers that run for #{seconds} s. Watch them in the tree."
    )
  end

  defp run_command(socket, "crash", _args) do
    case Harness.crash_worker() do
      {:ok, label} ->
        note(socket, :info, "Killed #{label}. Its supervisor starts it again.")

      {:error, :no_workers} ->
        note(socket, :info, "No workers are running. Start some with /spawn.")
    end
  end

  defp run_command(socket, "stop", _args) do
    case Agent.interrupt(socket.assigns.session_id) do
      :ok -> socket
      {:error, :idle} -> note(socket, :info, "Nothing is running.")
    end
  end

  defp run_command(socket, "clear", _args) do
    case Agent.reset(socket.assigns.session_id) do
      :ok ->
        socket
        |> stream(:entries, [], reset: true)
        |> assign(
          context_messages: 0,
          context_tokens: nil,
          live_turn: nil,
          turn_stats: nil,
          last_request: nil,
          tool_pids: %{},
          code_runs: %{}
        )

      {:error, :busy} ->
        note(socket, :info, "Stop the running prompt before clearing.")
    end
  end

  defp run_command(socket, "effort", [effort | _]), do: configure(socket, effort: effort)
  defp run_command(socket, "think", ["on" | _]), do: configure(socket, thinking: true)
  defp run_command(socket, "think", ["off" | _]), do: configure(socket, thinking: false)

  defp run_command(socket, command, _args) when command in ~w(effort think) do
    note(socket, :error, "/#{command} needs a value. Type /help for the options.")
  end

  defp run_command(socket, command, _args) do
    note(socket, :error, "There is no /#{command} command. Type /help for the list.")
  end

  defp int_arg(args, index, default, range) do
    with value when is_binary(value) <- Enum.at(args, index),
         {n, ""} <- Integer.parse(value) do
      n |> max(range.first) |> min(range.last)
    else
      _ -> default
    end
  end

  defp configure(socket, settings) do
    case Agent.configure(socket.assigns.session_id, settings) do
      {:ok, _settings} -> socket
      {:error, message} -> note(socket, :error, message)
    end
  end

  ## Events from the harness

  @impl true
  def handle_info({:observer, :snapshot, snapshot}, socket) do
    {:noreply, assign(socket, :snapshot, snapshot)}
  end

  def handle_info({:observer, :events, events}, socket) do
    {:noreply, stream(socket, :events, events, limit: -@log_limit)}
  end

  def handle_info({:agent, event}, socket), do: {:noreply, agent_event(event, socket)}

  defp agent_event({:user, text}, socket), do: add_entry(socket, %{type: :user, text: text})

  defp agent_event({:turn_start, info}, socket) do
    turn = %{
      id: "turn-#{info.turn}",
      type: :turn,
      turn: info.turn,
      pid: pid_text(info.pid),
      reasoning: "",
      content: "",
      tool_calls: [],
      streaming: true,
      finish_reason: nil,
      stats: nil
    }

    socket
    |> assign(
      live_turn: turn,
      turn_stats: %{turn: info.turn, chunks: 0},
      provider: info.provider,
      context_messages: info.messages
    )
    |> stream_insert(:entries, turn)
  end

  defp agent_event({:request, turn, json}, socket) do
    assign(socket, :last_request, %{turn: turn, json: json})
  end

  defp agent_event({:stream, n, snapshot}, %{assigns: %{live_turn: %{turn: n}}} = socket) do
    turn =
      Map.merge(socket.assigns.live_turn, Map.take(snapshot, [:reasoning, :content, :tool_calls]))

    socket
    |> assign(live_turn: turn, turn_stats: %{socket.assigns.turn_stats | chunks: snapshot.chunks})
    |> stream_insert(:entries, turn)
  end

  # A late chunk from a turn that already ended.
  defp agent_event({:stream, _turn, _snapshot}, socket), do: socket

  defp agent_event({:turn_end, %{turn: n} = info}, %{assigns: %{live_turn: %{turn: n}}} = socket) do
    final = Map.get(info, :final) || %{}

    turn =
      %{
        socket.assigns.live_turn
        | streaming: false,
          finish_reason: info.finish_reason,
          stats: info
      }
      |> Map.merge(%{
        reasoning: final[:reasoning] || socket.assigns.live_turn.reasoning,
        content: final[:content] || socket.assigns.live_turn.content
      })

    socket
    |> assign(
      live_turn: nil,
      turn_stats: Map.merge(socket.assigns.turn_stats, info),
      totals: add_usage(socket.assigns.totals, info[:usage]),
      context_tokens: context_tokens(info[:usage]) || socket.assigns.context_tokens
    )
    |> stream_insert(:entries, turn)
  end

  defp agent_event({:turn_end, _info}, socket), do: socket

  defp agent_event({:tool_start, call}, socket) do
    entry = tool_entry(call)

    code_runs =
      if call.name == "elixir",
        do: Map.put(socket.assigns.code_runs, call.id, entry),
        else: socket.assigns.code_runs

    socket
    |> assign(
      tool_pids: Map.put(socket.assigns.tool_pids, call.id, pid_text(call.pid)),
      tools_running: socket.assigns.tools_running + 1,
      code_runs: code_runs
    )
    |> stream_insert(:entries, entry)
  end

  defp agent_event({:tool_end, call}, socket) do
    {run, code_runs} = Map.pop(socket.assigns.code_runs, call.id)
    entry = tool_entry(call)
    entry = if run, do: %{entry | calls: run.calls, call_count: run.call_count}, else: entry

    socket
    |> assign(tools_running: max(socket.assigns.tools_running - 1, 0), code_runs: code_runs)
    |> stream_insert(:entries, entry)
  end

  # One V call inside a running elixir script.
  defp agent_event({:code_call, call_id, call}, socket) do
    case socket.assigns.code_runs do
      %{^call_id => entry} ->
        entry = put_code_call(entry, call)

        socket
        |> assign(:code_runs, Map.put(socket.assigns.code_runs, call_id, entry))
        |> stream_insert(:entries, entry)

      _ ->
        socket
    end
  end

  defp agent_event({:status, status}, socket) do
    socket = assign(socket, :status, status)
    if status == :idle, do: assign(socket, :tools_running, 0), else: socket
  end

  defp agent_event({:note, level, text}, socket), do: note(socket, level, text)

  defp agent_event({:context, messages}, socket), do: assign(socket, :context_messages, messages)

  defp agent_event({:settings, settings}, socket) do
    assign(socket,
      settings: Map.take(settings, [:effort, :thinking]),
      provider: settings.provider,
      context_messages: settings.messages
    )
  end

  defp tool_entry(call) do
    %{
      id: "tool-" <> dom_safe(call.id),
      type: :tool,
      call_id: call.id,
      name: call.name,
      arguments: call.arguments,
      status: call.status,
      result: Map.get(call, :result),
      ms: Map.get(call, :ms),
      code: if(call.name == "elixir", do: script(call.arguments)),
      calls: [],
      call_count: 0
    }
  end

  defp script(arguments) do
    case Jason.decode(arguments) do
      {:ok, %{"code" => code}} when is_binary(code) -> code
      _ -> arguments
    end
  end

  # Calls arrive in order, each first as :running and then finished.
  defp put_code_call(entry, call) do
    calls =
      cond do
        call.n <= length(entry.calls) -> List.replace_at(entry.calls, call.n - 1, call)
        call.n <= @shown_calls -> entry.calls ++ [call]
        true -> entry.calls
      end

    %{entry | calls: calls, call_count: max(entry.call_count, call.n)}
  end

  defp note(socket, level, text), do: add_entry(socket, %{type: :note, level: level, text: text})

  defp add_entry(socket, entry) do
    stream_insert(
      socket,
      :entries,
      Map.put(entry, :id, "e-#{System.unique_integer([:positive])}")
    )
  end

  defp add_usage(totals, nil), do: %{totals | turns: totals.turns + 1}

  defp add_usage(totals, usage) do
    %{
      totals
      | turns: totals.turns + 1,
        prompt: totals.prompt + (usage["prompt_tokens"] || 0),
        completion: totals.completion + (usage["completion_tokens"] || 0),
        cache_hit: totals.cache_hit + (usage["prompt_cache_hit_tokens"] || 0),
        cache_miss: totals.cache_miss + (usage["prompt_cache_miss_tokens"] || 0),
        reasoning:
          totals.reasoning +
            (get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) || 0)
    }
  end

  defp context_tokens(%{"prompt_tokens" => prompt, "completion_tokens" => completion})
       when is_integer(prompt) and is_integer(completion),
       do: prompt + completion

  defp context_tokens(_usage), do: nil

  defp turn_rows(stats) do
    usage = stats[:usage] || %{}

    [
      {"First token", seconds(stats[:ttft_ms])},
      {"Duration", seconds(stats[:ms])},
      {"Chunks", number(stats[:chunks])},
      {"Finish", stats[:finish_reason] || "streaming"},
      {"Tokens in", number(usage["prompt_tokens"])},
      {"Tokens out", number(usage["completion_tokens"])},
      {"Cached", number(usage["prompt_cache_hit_tokens"])},
      {"Reasoning", number(get_in(usage, ["completion_tokens_details", "reasoning_tokens"]))}
    ]
  end

  defp key_text(:env), do: "from environment"
  defp key_text(:dotenv), do: "from .env"
  defp key_text(:none), do: "not set"

  defp endpoint_text(nil), do: "none"
  defp endpoint_text(url), do: URI.parse(url).host || url

  defp max_tokens_text(nil), do: "API default"
  defp max_tokens_text(max), do: "#{number(max)} tokens"

  defp placeholder(:idle), do: "Ask the agent, or type /help"
  defp placeholder(_status), do: "Working. Press Escape or Stop to interrupt."
end
