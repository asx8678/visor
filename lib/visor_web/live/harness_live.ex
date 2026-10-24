defmodule VisorWeb.HarnessLive do
  @moduledoc """
  The harness view: the live supervision tree on the left, the agent
  console in the middle and the model inspector on the right.

  Each connected view starts its own session (a supervisor with an agent
  and a task supervisor) under `Visor.Harness`, so it shows up in the tree.
  """
  use VisorWeb, :live_view

  import VisorWeb.{ConsoleComponents, InspectorComponents, ProcessComponents}

  alias Visor.{Agent, Harness, Jobs, Model, Observer, SessionLog, Usage}
  alias Visor.Agent.Totals
  alias VisorWeb.ModelCall

  @log_limit 150
  @empty_snapshot %{tree: [], stats: %{}, apps: [], history: []}

  @examples [
    "List the files in this project",
    "Read mix.exs",
    "Search for Supervisor",
    "Run the tests",
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
        log_path: nil,
        snapshot: Observer.snapshot() || @empty_snapshot,
        provider: Model.current().info(),
        status: :idle,
        settings: %{effort: "high", thinking: true},
        # The running prompt's work entry and its streaming turn, and the
        # last prompt's work for the timeline once it is done.
        work: nil,
        last_work: nil,
        live_turn: nil,
        turn_stats: nil,
        # The session's finished model calls, newest first.
        turn_history: [],
        # The running prompt's model call, as %{n, max}, and the time the
        # elapsed clock reads, moved on with each runtime snapshot.
        step: nil,
        now: System.monotonic_time(:millisecond),
        totals: %Totals{},
        context_messages: 0,
        context_tokens: nil,
        last_request: nil,
        tools_running: 0,
        early_notes: %{},
        examples: @examples,
        form: to_form(%{"text" => ""}, as: :prompt)
      )
      |> stream(:entries, [])
      |> stream(:events, [])
      |> stream(:jobs, [], dom_id: &"job-#{&1.id}")

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
        <div class="space-y-2.5 border-b border-rule px-4 py-3">
          <h2 class="font-display text-lg font-medium text-ink">Processes</h2>
          <.app_strip apps={@snapshot.apps} />
          <.prompt_timeline work={@work || @last_work} now={@now} />
        </div>

        <div class="border-b border-rule px-4 py-2">
          <h3 class="pb-1 text-xs text-ink-dim">Background jobs</h3>
          <ol id="jobs" phx-update="stream">
            <li id="jobs-empty" class="hidden text-xs text-ink-dim only:block">
              None yet. A script starts one with V.sh(command, background: true).
            </li>
            <.job_row :for={{id, job} <- @streams.jobs} id={id} job={job} />
          </ol>
        </div>

        <div class="min-h-0 flex-1 overflow-y-auto px-3 py-2">
          <.supervision_tree
            tree={@snapshot.tree}
            activity={
              tree_activity(@session_id, @status, @tools_running, @work, @live_turn, @now)
              |> Map.merge(tab_marker(@session_id, @snapshot.tree))
            }
          />
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
            id="console-entries"
            phx-hook=".CopyCode"
            class="mx-auto max-w-3xl space-y-5 px-5 py-6 phone:px-4 phone:py-5"
          >
            <div id="entries" phx-update="stream" class="space-y-5">
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
              />
            </div>
            <%!-- The running prompt's work, outside the stream, so an update sends
                 only the step that changed; it joins the stream when the prompt ends. --%>
            <.entry :if={@work} id="work-live" entry={@work} />
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
            <div class="min-w-0 flex-1 [&_.field]:m-0">
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
        class="visor-model min-h-0 overflow-y-auto border-l border-rule bg-panel"
        aria-label="Model"
      >
        <div class="space-y-2.5 px-4 py-3">
          <div class="flex items-center justify-between gap-3">
            <h2 class="font-display text-lg font-medium text-ink">Model</h2>
            <.status_readout status={@status} tools_running={@tools_running} live_turn={@live_turn} />
          </div>
          <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1.5">
            <.segmented
              id="thinking-mode"
              label="Thinking"
              options={["on", "off"]}
              selected={if(@settings.thinking, do: "on", else: "off")}
              event="configure"
              key="thinking"
            />
            <.segmented
              id="reasoning-effort"
              label="Effort"
              options={Agent.efforts()}
              selected={@settings.effort}
              event="configure"
              key="effort"
              class={not @settings.thinking && "opacity-50"}
            />
          </div>
          <.step_meter :if={@work && @step} step={@step} ms={max(@now - @work.started, 0)} />
        </div>

        <.inspector_section
          title={"Context · #{count(@context_messages, "message")}"}
          aside={context_text(@context_tokens, @provider[:context_window])}
        >
          <.context_meter tokens={@context_tokens} window={@provider[:context_window]} />
        </.inspector_section>

        <.inspector_section
          :if={@turn_stats}
          id="turn-readings"
          title={"Model call #{@turn_stats.turn}"}
          aside={ModelCall.finish_text(@turn_stats[:finish_reason])}
        >
          <.readings cols={2} rows={turn_rows(@turn_stats)} />
        </.inspector_section>

        <.inspector_section title="Model calls" aside="time · in · out">
          <.turn_history turns={Enum.take(@turn_history, 40)} live={@live_turn} now={@now} />
        </.inspector_section>

        <.inspector_section
          id="session-readings"
          title="This session"
          aside={count(@totals.turns, "model call")}
        >
          <.readings cols={2} rows={session_rows(@totals)} />
          <.cache_bar
            hit={@totals.cached_tokens}
            miss={@totals.uncached_tokens}
            unmeasured={Map.get(@totals, :unmeasured_tokens, 0)}
          />
          <.readings :if={@log_path} id="session-log" rows={[{"Log", @log_path}]} />
        </.inspector_section>

        <.fold
          id="provider"
          title="Provider"
          aside={"#{@provider.provider} · key #{key_text(@provider.key)}"}
        >
          <.readings rows={[
            {"Model", @provider.model},
            {"Endpoint", endpoint_text(@provider[:endpoint])},
            {"Max output", max_tokens_text(@provider[:max_tokens])},
            {"Context window", max_tokens_text(@provider[:context_window])}
          ]} />
        </.fold>

        <.fold
          id="last-request"
          title={
            if(@last_request,
              do: "Request for model call #{@last_request.turn}",
              else: "Last request"
            )
          }
        >
          <pre
            :if={@last_request}
            class="max-h-96 overflow-auto bg-well p-2.5 font-mono text-xs leading-relaxed whitespace-pre-wrap break-words text-ink/80"
          >{@last_request.json}</pre>
          <p :if={!@last_request} class="text-xs text-ink-dim">
            The request body appears here when the agent calls the model.
          </p>
        </.fold>
      </aside>

      <.panel_tabs
        status={@status}
        process_count={Enum.count(@snapshot.tree, &(!&1[:ghost]))}
        key={@provider.key}
      />

      <div id="client-layout" phx-hook=".ClientLayout" hidden></div>

      <.hooks />
    </Layouts.app>
    """
  end

  # The page's JS hooks, kept out of render. Colocated hooks are named
  # for the module that defines them, so they stay in this one.
  defp hooks(assigns) do
    ~H"""
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

  def handle_event("stop_job", %{"id" => job_id}, socket),
    do: {:noreply, run_command(socket, "jobs", ["stop", job_id])}

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

  # While a prompt runs, the text steers it; the agent's steer event says so.
  defp send_input(socket, text) do
    case Agent.prompt(socket.assigns.session_id, text) do
      :ok -> socket
      :queued -> socket
    end
  end

  ## Slash commands

  defp run_command(socket, "help", _args), do: add_entry(socket, %{type: :help})

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
        # The session's model calls and totals stay: they are numbered
        # and counted for the whole session.
        |> assign(
          context_messages: 0,
          context_tokens: nil,
          work: nil,
          last_work: nil,
          live_turn: nil,
          step: nil
        )

      {:error, :busy} ->
        note(socket, :info, "Stop the running prompt before clearing.")
    end
  end

  # The agent's compaction event writes the note when it compacts.
  defp run_command(socket, "compact", _args) do
    case Agent.compact(socket.assigns.session_id) do
      {:ok, _info} ->
        socket

      {:error, :nothing} ->
        note(socket, :info, "There is nothing to compact yet.")

      {:error, :busy} ->
        note(socket, :info, "Stop the running prompt before compacting.")
    end
  end

  defp run_command(socket, "scripts", _args) do
    case Visor.Scripts.list() do
      [] ->
        note(socket, :info, "No saved scripts yet. A script saves one with V.save(name, code).")

      scripts ->
        lines = Enum.map_join(scripts, "\n", &"#{&1.name}  #{&1.description}")
        note(socket, :info, "Saved scripts (run one with /run name):\n" <> lines)
    end
  end

  # A saved script runs without the model, as a script of its own under
  # the session; its result comes back as a note.
  defp run_command(socket, "run", [name | _]) do
    id = socket.assigns.session_id
    context = %{session: id, call_id: "run-#{System.unique_integer([:positive])}"}

    Harness.async(Harness.via({id, :tasks}), "run #{name}", fn ->
      {status, text, _calls} = Visor.Code.execute("V.run(#{inspect(name)})", context)
      {:script_run, name, status, text}
    end)

    note(socket, :info, "Running saved script #{name}…")
  end

  defp run_command(socket, "run", []) do
    note(socket, :error, "/run needs a saved script's name. /scripts lists them.")
  end

  defp run_command(socket, "jobs", []) do
    case Jobs.list(socket.assigns.session_id) do
      [] ->
        note(socket, :info, "No background jobs yet.")

      jobs ->
        lines = Enum.map_join(jobs, "\n", &"#{&1.id}  #{&1.status}  #{Jobs.label(&1)}")
        note(socket, :info, "Background jobs:\n" <> lines)
    end
  end

  defp run_command(socket, "jobs", ["stop", job_id | _]) do
    case Jobs.stop(socket.assigns.session_id, job_id) do
      {:ok, %{status: :killed}} -> note(socket, :info, "Stopped job #{job_id}.")
      {:ok, job} -> note(socket, :info, "Job #{job_id} had ended already (#{job.status}).")
      {:error, message} -> note(socket, :error, message)
    end
  end

  defp run_command(socket, "jobs", ["wake", value | _]) when value in ~w(on off) do
    socket = configure(socket, jobs_wake: value == "on")

    note(
      socket,
      :info,
      if(value == "on",
        do: "A background job that ends may start the agent on its own.",
        else: "Background jobs that end now wait for your next prompt."
      )
    )
  end

  defp run_command(socket, "jobs", _args) do
    note(socket, :error, "/jobs takes nothing, stop ID or wake on|off. Type /help for the list.")
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

  defp configure(socket, settings) do
    case Agent.configure(socket.assigns.session_id, settings) do
      {:ok, _settings} -> socket
      {:error, message} -> note(socket, :error, message)
    end
  end

  ## Events from the harness

  @impl true
  def handle_info({:observer, :snapshot, snapshot}, socket) do
    {:noreply, assign(socket, snapshot: snapshot, now: System.monotonic_time(:millisecond))}
  end

  # What a script or sandbox starts for itself stays out of the log.
  def handle_info({:observer, :events, events}, socket) do
    case Enum.reject(events, &Map.get(&1, :minor, false)) do
      [] -> {:noreply, socket}
      events -> {:noreply, stream(socket, :events, events, limit: -@log_limit)}
    end
  end

  def handle_info({ref, {:script_run, name, status, text}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    level = if status == :ok, do: :info, else: :error
    {:noreply, note(socket, level, "Saved script #{name}:\n" <> text)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}

  def handle_info({:agent, event}, socket),
    do: {:noreply, socket |> tally(event) |> show_log() |> then(&agent_event(event, &1))}

  # The session log's file is created with the agent's first event, so its
  # path shows from then on.
  defp show_log(%{assigns: %{log_path: nil, session_id: id}} = socket) when is_binary(id),
    do: assign(socket, :log_path, log_path(id))

  defp show_log(socket), do: socket

  # The session's totals, and the running prompt's for its work line.
  defp tally(socket, event) do
    work =
      socket.assigns.work &&
        %{socket.assigns.work | totals: Totals.add(socket.assigns.work.totals, event)}

    assign(socket, totals: Totals.add(socket.assigns.totals, event), work: work)
  end

  # A prompt shows as the user's text, one work entry that folds up every
  # model turn and tool call it took, and the answer.
  defp agent_event({:user, text}, socket) do
    socket |> add_entry(%{type: :user, text: text}) |> start_work()
  end

  # A prompt of the agent's own works as the user's does.
  defp agent_event({:wake, text}, socket) do
    socket |> add_entry(%{type: :wake, text: text}) |> start_work()
  end

  defp agent_event({:job_start, job}, socket), do: stream_insert(socket, :jobs, job)

  defp agent_event({:job_end, job}, socket), do: stream_insert(socket, :jobs, job)

  defp agent_event({:steer, text}, socket) do
    note(socket, :info, "Sent to the running prompt, for after its current step: " <> text)
  end

  defp agent_event({:turn_start, info}, socket) do
    turn = %{
      id: "turn-#{info.turn}",
      type: :turn,
      turn: info.turn,
      started: System.monotonic_time(:millisecond),
      chunks: 0,
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
      step: %{n: info.step, max: info.max_steps},
      provider: info.provider,
      context_messages: info.messages
    )
    |> put_step(turn)
  end

  # This view owns the session, so a request that can't be shown as JSON
  # is shown another way rather than ending it.
  defp agent_event({:request, turn, preview}, socket) do
    json =
      case Jason.encode(preview, pretty: true) do
        {:ok, json} -> json
        {:error, _reason} -> inspect(preview, pretty: true, printable_limit: 4096)
      end

    assign(socket, :last_request, %{turn: turn, json: json})
  end

  defp agent_event({:stream, n, snapshot}, %{assigns: %{live_turn: %{turn: n}}} = socket) do
    turn =
      Map.merge(
        socket.assigns.live_turn,
        Map.take(snapshot, [:reasoning, :content, :tool_calls, :chunks])
      )

    socket
    |> assign(live_turn: turn)
    |> put_step(turn)
  end

  # A late chunk from a turn that already ended.
  defp agent_event({:stream, _turn, _snapshot}, socket), do: socket

  defp agent_event({:turn_end, %{turn: n} = info}, %{assigns: %{live_turn: %{turn: n}}} = socket) do
    final = Map.get(info, :final) || %{}
    usage = Usage.from(info[:usage])
    content = final[:content] || socket.assigns.live_turn.content

    turn =
      Map.merge(socket.assigns.live_turn, %{
        streaming: false,
        finish_reason: info.finish_reason,
        stats: info,
        reasoning: final[:reasoning] || socket.assigns.live_turn.reasoning,
        content: content
      })

    # The reply that ends a prompt is its answer, shown below the work once
    # the work joins the stream.
    {turn, answer} =
      if info.finish_reason in ["stop", "length"] and content not in [nil, ""],
        do: {%{turn | content: ""}, %{id: "answer-#{n}", type: :answer, text: content}},
        else: {turn, nil}

    socket
    |> assign(
      live_turn: nil,
      turn_stats: Map.merge(%{chunks: socket.assigns.live_turn.chunks}, info),
      turn_history: [history_row(info, usage) | Enum.take(socket.assigns.turn_history, 199)],
      context_tokens: Usage.context(usage) || socket.assigns.context_tokens
    )
    |> put_step(turn)
    |> update_work(&Map.put(&1, :answer, answer || &1[:answer]))
  end

  defp agent_event({:turn_end, _info}, socket), do: socket

  defp agent_event({:tool_start, call}, socket) do
    # Notes the script showed before this event reached the page.
    {notes, early} = Map.pop(Map.get(socket.assigns, :early_notes, %{}), call.id, [])

    socket
    |> assign(tools_running: socket.assigns.tools_running + 1, early_notes: early)
    |> put_step(%{tool_entry(call) | pid: pid_text(call.pid), started: now(), notes: notes})
  end

  defp agent_event({:tool_end, call}, socket) do
    entry = tool_entry(call)

    entry =
      case find_step(socket, entry.id) do
        %{} = run ->
          %{
            entry
            | calls: run.calls,
              call_count: run.call_count,
              pid: run.pid,
              started: Map.get(run, :started),
              notes: Map.get(run, :notes, [])
          }

        nil ->
          entry
      end

    socket
    |> assign(tools_running: max(socket.assigns.tools_running - 1, 0))
    |> put_step(entry)
  end

  # One V call inside a running elixir script. The full arguments and
  # value, such as a file's contents, are for the session log.
  # A script runs as soon as its task starts, so a note can come before
  # the call's tool_start; it waits for it.
  defp agent_event({:script_note, call_id, text}, socket) do
    case find_step(socket, "tool-" <> dom_safe(call_id)) do
      %{} = entry ->
        put_step(socket, Map.update(entry, :notes, [text], &(&1 ++ [text])))

      nil ->
        early = Map.get(socket.assigns, :early_notes, %{})
        assign(socket, :early_notes, Map.update(early, call_id, [text], &(&1 ++ [text])))
    end
  end

  defp agent_event({:code_call, call_id, call}, socket) do
    case find_step(socket, "tool-" <> dom_safe(call_id)) do
      %{} = entry ->
        call = Map.drop(call, [:args, :returned])
        call = if call.status == :running, do: Map.put(call, :started, now()), else: call
        put_step(socket, put_code_call(entry, call))

      nil ->
        socket
    end
  end

  defp agent_event({:prompt_end, %{reason: reason}}, socket) do
    status =
      case reason do
        :answered -> :done
        :interrupted -> :stopped
        _failed -> :failed
      end

    socket = update_work(socket, &%{&1 | status: status, ms: now() - &1.started})

    case socket.assigns.work do
      nil ->
        socket

      work ->
        socket
        |> stream_insert(:entries, Map.delete(work, :answer))
        |> then(&if(work[:answer], do: stream_insert(&1, :entries, work.answer), else: &1))
        |> assign(work: nil, last_work: work)
    end
  end

  defp agent_event({:status, status}, socket) do
    socket = assign(socket, :status, status)
    if status == :idle, do: assign(socket, :tools_running, 0), else: socket
  end

  defp agent_event({:note, level, text}, socket), do: note(socket, level, text)

  defp agent_event({:context, messages}, socket), do: assign(socket, :context_messages, messages)

  defp agent_event({:repeat, %{blocked: true, count: count}}, socket) do
    note(
      socket,
      :info,
      "The model ran the same script #{count} times in a row, so Visor refused this run."
    )
  end

  defp agent_event({:repeat, _info}, socket), do: socket

  defp agent_event({:repair, %{reason: :arguments, fixes: fixes}}, socket),
    do: note(socket, :info, "Read the tool call's arguments as meant: #{Enum.join(fixes, ", ")}.")

  defp agent_event({:repair, info}, socket) do
    why =
      if info.reason == :restart,
        do: "The agent restarted in the middle of a batch",
        else: "The conversation had tool calls out of order"

    note(
      socket,
      :info,
      "#{why}, so before the next request it answered #{count(info.answered, "tool call")} " <>
        "and dropped #{count(info.dropped, "stray result")}."
    )
  end

  defp agent_event({:compaction, info}, socket) do
    why =
      case info.reason do
        :threshold -> "it passed its threshold"
        :manual -> "you asked"
        :overflow -> "the model rejected it as too long"
        :requested -> "the model asked (#{info[:request]})"
      end

    note(
      socket,
      :info,
      "Compacted the conversation because #{why}: #{count(info.summarized, "message")} " <>
        "became a summary, about #{short(info.tokens_before)} → #{short(info.tokens_after)} tokens."
    )
  end

  defp agent_event({:settings, settings}, socket) do
    assign(socket,
      settings: Map.take(settings, [:effort, :thinking]),
      provider: settings.provider,
      context_messages: settings.messages
    )
  end

  # Events only the session log uses, such as the request as sent.
  defp agent_event(_event, socket), do: socket

  # Adds a step to the running work entry, or replaces the one with its id.
  defp put_step(socket, step) do
    update_work(socket, fn work ->
      steps =
        case Enum.find_index(work.steps, &(&1.id == step.id)) do
          nil -> work.steps ++ [step]
          index -> List.replace_at(work.steps, index, step)
        end

      %{work | steps: steps}
    end)
  end

  defp find_step(%{assigns: %{work: %{steps: steps}}}, id), do: Enum.find(steps, &(&1.id == id))
  defp find_step(_socket, _id), do: nil

  # Events outside a prompt, such as after /clear, have no work to go in.
  defp update_work(%{assigns: %{work: nil}} = socket, _fun), do: socket
  defp update_work(socket, fun), do: assign(socket, work: fun.(socket.assigns.work))

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
      pid: nil,
      started: nil,
      code: if(call.name == "elixir", do: script(call.arguments)),
      calls: [],
      call_count: 0,
      notes: []
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

  # What the session's processes are doing, for their rows in the process
  # tree: keyed by pid text, or by label for the session and its agent.
  defp tree_activity(nil, _status, _tools, _work, _turn, _now), do: %{}

  defp tree_activity(id, status, tools_running, work, live_turn, now) do
    steps = if work, do: work.steps, else: []

    tools =
      for %{type: :tool, status: :running, pid: pid} = tool <- steps, pid, into: %{} do
        {pid, %{text: tool_doing(tool, now), tone: :tool}}
      end

    model =
      if live_turn && live_turn.pid,
        do: %{live_turn.pid => %{text: model_doing(live_turn, now), tone: :model}},
        else: %{}

    agent =
      case status do
        :streaming -> "waiting on the model"
        :tools -> "waiting on " <> count(max(tools_running, 1), "tool call")
        _idle -> nil
      end

    if(agent, do: %{"agent #{id}" => %{text: agent, tone: :plain}}, else: %{})
    |> Map.merge(model)
    |> Map.merge(tools)
  end

  # With more than one session open, which one is this tab's.
  defp tab_marker(nil, _tree), do: %{}

  defp tab_marker(id, tree) do
    sessions = Enum.count(tree, &(String.starts_with?(&1.label, "session ") and !&1[:ghost]))

    if sessions > 1,
      do: %{"session #{id}" => %{text: "this tab", tone: :plain, inline: true}},
      else: %{}
  end

  defp model_doing(turn, now) do
    # The first chunks may carry no text yet, only the reply's role.
    text =
      case ModelCall.phase(turn) do
        :waiting -> ModelCall.phase_text(:waiting)
        phase -> "#{ModelCall.phase_text(phase)} · #{count(turn.chunks, "chunk")}"
      end

    text <> since(turn.started, now)
  end

  defp tool_doing(tool, now) do
    case List.last(tool.calls) do
      %{status: :running, started: started} = call ->
        "V.#{call.text} · #{seconds(max(now - started, 0))} · call #{call.n}"

      %{} ->
        "script running · #{count(tool.call_count, "V call")}" <> since(tool.started, now)

      nil ->
        "script starting" <> since(tool.started, now)
    end
  end

  defp since(nil, _now), do: ""
  defp since(started, now), do: " · #{seconds(max(now - started, 0))}"

  defp now, do: System.monotonic_time(:millisecond)

  defp note(socket, level, text), do: add_entry(socket, %{type: :note, level: level, text: text})

  # The running prompt's work entry, which its model turns and tool calls
  # fold into.
  defp start_work(socket) do
    work = %{
      id: "work-#{System.unique_integer([:positive])}",
      type: :work,
      steps: [],
      status: :running,
      started: System.monotonic_time(:millisecond),
      ms: nil,
      totals: %Totals{}
    }

    assign(socket, work: work, last_work: nil, step: nil)
  end

  defp add_entry(socket, entry) do
    stream_insert(
      socket,
      :entries,
      Map.put(entry, :id, "e-#{System.unique_integer([:positive])}")
    )
  end

  defp cache_hit(usage) do
    case Usage.hit_share(usage) do
      nil -> if usage.prompt, do: "unknown", else: "–"
      share -> "#{share}%"
    end
  end

  defp turn_rows(stats) do
    usage = Usage.from(stats[:usage]) || %Usage{}

    [
      {"First token", seconds(stats[:ttft_ms])},
      {"Duration", seconds(stats[:ms])},
      {"In", short(usage.prompt)},
      {"Cached", short(usage.cached)},
      {"Cache hit", cache_hit(usage)},
      {"Out", short(usage.completion)},
      {"Reasoning", short(usage.reasoning)},
      {"Chunks", number(stats[:chunks])},
      {"Speed", speed(usage.completion, stats[:ms], stats[:ttft_ms])}
    ]
  end

  defp history_row(info, usage) do
    usage = usage || %Usage{}

    %{
      turn: info.turn,
      ms: info[:ms],
      ttft_ms: info[:ttft_ms],
      prompt: usage.prompt,
      cached: usage.cached,
      completion: usage.completion,
      finish: info.finish_reason
    }
  end

  defp session_rows(totals) do
    [
      {"In", short(totals.prompt_tokens)},
      {"Out", short(totals.completion_tokens)},
      {"Reasoning", short(totals.reasoning_tokens)},
      {"Uncached", short(totals.uncached_tokens)},
      failures("Tool calls", totals.tool_calls, totals.tool_errors),
      failures("V calls", totals.v_calls, totals.v_errors),
      {"Model time", seconds(totals.model_ms)},
      {"Tool time", seconds(totals.tool_ms)}
    ]
  end

  defp failures(label, n, 0), do: {label, number(n)}
  defp failures(label, n, failed), do: {label, "#{number(n)}, #{number(failed)} failed", :alarm}

  defp key_text(:env), do: "env"
  defp key_text(:dotenv), do: ".env"
  defp key_text(:none), do: "not set"

  defp endpoint_text(nil), do: "none"
  defp endpoint_text(url), do: URI.parse(url).host || url

  defp max_tokens_text(nil), do: "API default"
  defp max_tokens_text(max), do: "#{number(max)} tokens"

  defp context_text(nil, nil), do: nil
  defp context_text(nil, window), do: "#{short(window)} window"
  defp context_text(tokens, nil), do: "#{short(tokens)} tokens"

  defp context_text(tokens, window),
    do: "#{short(tokens)} of #{short(window)} · #{percent(tokens, window)}"

  defp percent(part, whole), do: :erlang.float_to_binary(part * 100 / whole, decimals: 1) <> "%"

  # Output tokens a second, from the first token to the last.
  defp speed(tokens, ms, ttft)
       when is_integer(tokens) and is_integer(ms) and is_integer(ttft) and ms > ttft,
       do: "#{round(tokens * 1000 / (ms - ttft))}/s"

  defp speed(_tokens, _ms, _ttft), do: "–"

  defp placeholder(:idle), do: "Ask the agent, or type /help"
  defp placeholder(_status), do: "Working. Type to steer it, or press Escape or Stop."

  # The session's log file, relative to the project when it is inside it.
  defp log_path(id) do
    with path when is_binary(path) <- SessionLog.path(id), do: Path.relative_to_cwd(path)
  end
end
