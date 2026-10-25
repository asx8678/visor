defmodule Visor.Agent do
  @moduledoc """
  The agent loop for one console session.

  Each model call and each tool call runs as its own task under the
  session's task supervisor. That keeps the loop responsive (it can be
  interrupted mid-stream) and puts every step in the process view. Each
  task has a deadline (`Visor.Limits`), past which the agent stops it.

  The conversation is kept in the session's table (see
  `Visor.Harness.Session`), so the agent picks it up again after a crash.
  Once it grows past its threshold, the agent compacts it at the next
  settled step: a new prompt, or a batch's results all in (see
  `Visor.Compaction`).

  It publishes what it does as events; see `Visor.Agent.Event`.
  """
  use GenServer

  alias Visor.{Compaction, Harness, Jobs, Limits, Model, Tools, Usage}
  alias Visor.Agent.{Event, Repair, Wakes}
  alias Visor.Harness.Session

  # Model calls allowed for one prompt. The last runs without tools, so the
  # model reports where it got to instead of stopping mid-task. The
  # spending limits and the repeat guard bound what a prompt costs; this
  # bounds its length (a live build of a 3D page needed 39 calls over two
  # prompts, cut at 24).
  @max_steps 40
  # From this many calls left, each tool result says how many remain.
  @warn_steps 4
  @efforts ~w(low high max)

  @system """
  You are Visor, a coding agent running inside an Elixir/OTP harness. You explore, read \
  and change the user's project and run shell commands in it with the elixir tool. Every \
  model call and script you run is its own supervised BEAM process, which the user watches \
  in a live process view.

  Work in code mode: write one script per step that does every read, search, edit and \
  command the step needs, then returns only what you need to see.

  A change usually takes three steps:
  1. Look: read and search everything the change needs in one script.
  2. Change and check: make all the edits in one script and end it with V.check(), which \
  compiles and runs the tests and reports only the errors and failures.
  3. Fix and check: if the check failed, fix what it reports and end with V.check() again.

  Trust a script's result: it lists the files that changed and what failed, so don't read \
  a file again to confirm an edit. Read a cut output with V.output only when you need it.

  Keep answers short and concrete; the user reads them in a narrow console. Refer to files \
  by their path relative to the project root.
  """

  defstruct [
    :id,
    :owner_ref,
    :tasks,
    :model_task,
    # The session's table, where the conversation outlives this process.
    :store,
    messages: [],
    status: :idle,
    turn: 0,
    steps: 0,
    effort: "high",
    thinking: true,
    # The running batch of tool calls by task ref, each as %{call, index,
    # task, started, result}; the results go back in call order. A call
    # waiting its turn has no task yet and sits under a ref of its own.
    tools: %{},
    # Prompt tokens the last request sent, to notice when the next one
    # misses the provider's cache.
    last_prompt_tokens: nil,
    # What the model sees in place of the messages before `from`, as
    # %{from, summary}, or nil (see Visor.Compaction).
    compaction: nil,
    # What each tool call's script did, by tool call id, as %{status,
    # calls}, for compaction.
    facts: %{},
    # The last request's estimated size, and provider tokens per estimated
    # token as the provider counted it.
    last_estimate: nil,
    token_scale: 1.0,
    # Whether this prompt has compacted already after the provider
    # rejected a request as too long.
    overflowed: false,
    # What the user sent while a prompt ran, oldest first: it goes to the
    # model after the running tool calls, or starts the next prompt.
    queued: [],
    # The last script run and how many times in a row, as {hash, count}.
    repeat: nil,
    # Background jobs that ended and the model hasn't heard of yet, by id
    # (see Visor.Jobs). They reach it after the running tool calls, with
    # the next prompt, or as a prompt of their own: a wake.
    pending_jobs: [],
    # A reviewer's messages (see Visor.Reviewer), delivered as job notices
    # are; `wake_texts` when one of them may wake the agent.
    pending_texts: [],
    wake_texts: false,
    # Wakes since the user's last prompt (`monitor_wakes`: those for a
    # monitored job's lines alone), and whether they wait for the next one
    # (after Stop or a failed model call).
    wakes: 0,
    monitor_wakes: 0,
    wakes_held: false,
    jobs_wake: true,
    # The batch timer of the next wake, as {ref, timer}.
    wake_timer: nil,
    # What the model asked every summary to keep (V.carry/1), and its
    # request to compact once its prompt has ended (V.compact/1).
    carry: [],
    compact_request: nil,
    # This agent's limit of model calls a prompt, its system prompt, and
    # how deep under other agents it runs (0 for a console's own; see
    # V.agent/2).
    max_steps: @max_steps,
    system: @system,
    depth: 0,
    # Effort and thinking the model set for itself (V.think/2), as
    # %{effort, thinking, turns}, until the prompt ends, `turns` model
    # calls have used it, or the user changes either.
    think: nil,
    # While the page that owned the session is gone: when it ends.
    grace_timer: nil,
    # What the session and its running prompt have spent, and may
    # (Visor.Limits.prompt_cost_limit/0 and the rest).
    spent: nil,
    limits: nil,
    # A sub-agent's parent session: what it spends is the parent's too,
    # and before each model call it asks the parent what is left. The
    # parent's last answer, as caps on the sub-agent's own spending, for
    # when the parent doesn't answer in time (budget_limits/1).
    budget_parent: nil,
    parent_cap: nil
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :id)))
  end

  defdelegate subscribe(id), to: Event

  @doc """
  Tells session `id`'s agent that background job `job_id` has news: it
  ended, or its monitor holds lines (`Visor.Jobs.take_notice/2`).
  """
  def job_event(id, job_id), do: GenServer.cast(via(id), {:job_event, job_id})

  @doc """
  Gives session `id`'s agent a reviewer's message (`Visor.Reviewer`): the
  model gets it after the running tool calls or with the next prompt.
  With `wake: true` it may also start a prompt when the agent is idle,
  within the wake limit.
  """
  def review(id, text, wake), do: GenServer.cast(via(id), {:review, text, wake})
  def efforts, do: @efforts

  @doc """
  Sends a user prompt. While one is running it steers that one instead and
  returns `:queued`: the text reaches the model after the running tool
  calls, or starts the next prompt if the model answers first.
  """
  def prompt(id, text), do: GenServer.call(via(id), {:prompt, text})

  @doc """
  Sends a prompt with pictures the user attached, as `{name, part}`
  (`Visor.Content.image/2`): they go in its user message, or with the
  steering text while a prompt runs.
  """
  def prompt(id, text, []), do: prompt(id, text)
  def prompt(id, text, pictures), do: GenServer.call(via(id), {:prompt, text, pictures})

  @doc """
  Makes `owner` (a console page) session `id`'s owner again, within its
  grace period after the page it had went away. Returns `{:ok, settings}`,
  or `{:error, :in_use}` while another page owns it, `{:error, :sub_agent}`
  for a sub-agent's session, `{:error, :gone}` when it has ended.
  """
  def adopt(id, owner) do
    GenServer.call(via(id), {:adopt, owner})
  catch
    :exit, _reason -> {:error, :gone}
  end

  @doc """
  Replaces session `id`'s conversation with the one session `from`'s log
  left (`/resume`): the messages of its last request as sent, and its
  answer when the call ended with one, what its scripts did and what it
  carried. Returns `{:ok, message_count}` or `{:error, message}`.
  """
  def resume(id, from), do: GenServer.call(via(id), {:resume, from})

  @doc "Interrupts the running model call or tools."
  def interrupt(id), do: GenServer.call(via(id), :interrupt)

  @doc "Forgets the conversation."
  def reset(id), do: GenServer.call(via(id), :reset)

  @doc """
  Compacts the conversation now, under the threshold or not (`/compact`).
  Returns `{:ok, info}`, `{:error, :nothing}` when there is nothing to
  compact or no summary would fit, or `{:error, :busy}` while a prompt runs.
  """
  def compact(id), do: GenServer.call(via(id), :compact)

  @doc """
  The list of what every compaction summary keeps (`V.carry/1`), after
  `change`: `{:add, item}`, `{:remove, item}`, `:clear` or `:read`.
  Returns `{:ok, items}` or `{:error, message}`.
  """
  def carry(id, change), do: GenServer.call(via(id), {:carry, change})

  @doc """
  Asks for the conversation to be compacted once the running prompt has
  ended, at the next prompt's first model call (`V.compact/1`).
  """
  def request_compaction(id, reason), do: GenServer.call(via(id), {:request_compaction, reason})

  @doc """
  Sets the effort and thinking of this prompt's next model calls, as the
  model asked (`V.think/2`): `level` is `"off"` (no thinking), `"low"`,
  `"high"` or `"max"`, for `turns` calls or, with nil, the rest of the
  prompt. The user's own setting comes back after.
  """
  def think(id, level, turns), do: GenServer.call(via(id), {:think, level, turns})

  @doc """
  How full the context is: the last request's tokens, the threshold that
  compacts and the window (`V.context/0`).
  """
  def context(id), do: GenServer.call(via(id), :context)

  @doc """
  Changes `:effort`, `:thinking` or `:jobs_wake` (whether a background job
  that ends may start a prompt on its own).
  """
  def configure(id, settings), do: GenServer.call(via(id), {:configure, settings})

  def settings(id), do: GenServer.call(via(id), :settings)

  @doc """
  A tool result as the model first saw it, from session `id`'s table. It
  reads the table, not the agent, so a running script can call it (see
  `V.recall/1`).
  """
  def recall(nil, _call_id), do: {:error, "No conversation is kept outside a session."}

  def recall(id, call_id) do
    store = Session.store(id)

    case store && (kept_result(store, call_id) || resumed_result(store, call_id)) do
      content when is_binary(content) -> {:ok, content}
      _ -> {:error, "There is no tool result #{call_id} in this conversation."}
    end
  end

  defp kept_result(store, call_id) do
    with [{:conversation, %{messages: messages}}] <- :ets.lookup(store, :conversation),
         %{"content" => content} <-
           Enum.find(messages, &(&1["role"] == "tool" and &1["tool_call_id"] == call_id)),
         do: content,
         else: (_ -> nil)
  end

  # A resumed conversation starts with the summary its log's last request
  # had, whose calls' results are in that log, not in the messages.
  defp resumed_result(store, call_id) do
    case :ets.lookup(store, :resumed_results) do
      [{:resumed_results, results}] -> results[call_id]
      [] -> nil
    end
  end

  @doc """
  Session `id`'s conversation as its table keeps it, or `[]`. It reads
  the table, not the agent, so it answers while a prompt runs.
  """
  @spec messages(String.t()) :: [map()]
  def messages(id) do
    with store when store != nil <- Session.store(id),
         [{:conversation, %{messages: messages}}] <- :ets.lookup(store, :conversation) do
      messages
    else
      _none -> []
    end
  end

  @doc """
  Adds to session `id`'s spending what a model call of its own reviewer
  or sub-agents cost: `cost` in dollars (nil when unreported) and `tokens`.
  """
  @spec spent(String.t(), number() | nil, non_neg_integer() | nil) :: :ok
  def spent(id, cost, tokens), do: GenServer.cast(via(id), {:spent, cost, tokens})

  @doc """
  Holds a picture `V.image/1` asked for (an image part, see
  `Visor.Content`), for the user message after the batch's results.
  """
  def attach_image(id, path, part), do: GenServer.call(via(id), {:attach_image, path, part})

  @doc "The code of session `id`'s last script that worked, or nil (`/save`)."
  def last_script(id), do: GenServer.call(via(id), :last_script)

  @doc """
  What session `id` may still spend: `%{prompt: dollars, session:
  dollars, tokens: n}`, for a sub-agent to start with, and that the
  sub-agent asks for again before each of its model calls.
  """
  @spec allowance(String.t()) :: %{prompt: float(), session: float(), tokens: integer()}
  def allowance(id), do: GenServer.call(via(id), :allowance)

  @doc """
  A picture the user sent in session `id`, by the name its prompt gave it
  (`[The user's picture: NAME]`), for `V.image("picture:NAME")`: the
  session keeps the newest `Visor.Limits.pictures_kept/0`. Reads the
  session's table, so a running script can call it.
  """
  @spec user_picture(String.t() | nil, String.t()) :: {:ok, map()} | {:error, String.t()}
  def user_picture(id, name) do
    kept =
      with store when store != nil <- id && Session.store(id),
           [{:pictures, kept, _names}] <- :ets.lookup(store, :pictures) do
        kept
      else
        _none -> []
      end

    case List.keyfind(kept, name, 0) do
      {_name, part} ->
        {:ok, part}

      nil when kept == [] ->
        {:error, "This session keeps no picture the user sent."}

      nil ->
        {:error,
         "No picture the user sent is called #{name}. The ones kept: " <>
           Enum.map_join(kept, ", ", &elem(&1, 0)) <> "."}
    end
  end

  defp via(id), do: Harness.via({id, :agent})

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    Process.set_label("agent #{id}")
    owner_ref = Process.monitor(Keyword.fetch!(opts, :owner))

    state = %__MODULE__{
      id: id,
      owner_ref: owner_ref,
      tasks: Keyword.fetch!(opts, :tasks),
      store: Keyword.get(opts, :store),
      max_steps: Keyword.get(opts, :max_steps, @max_steps),
      system:
        system_prompt(Keyword.get(opts, :role), Keyword.get(opts, :read_only, false)) <>
          project_rules() <> Visor.Memory.prompt_text(),
      # A sub-agent's are what its parent's prompt had left (allowance/1).
      limits: Keyword.get(opts, :limits) || default_limits(),
      depth: Keyword.get(opts, :depth, 0),
      budget_parent: Keyword.get(opts, :budget_parent)
    }

    {:ok, restore(state)}
  end

  # The call may have run: its task outlives the agent, so a command it
  # started can finish after the restart (pi-fabric says "aborted").
  @restarted "No result: the agent restarted before this call finished. It may not have " <>
               "run, or run in part or in full: check before running it again."
  @missing "No result: this call's result was missing from the conversation."

  @impl true
  def handle_call({:prompt, text}, _from, %{status: :idle} = state) do
    {:reply, :ok, start_prompt(state, text)}
  end

  def handle_call({:prompt, text}, _from, state) do
    broadcast(state, {:steer, text})
    {:reply, :queued, save(Map.put(state, :queued, Map.get(state, :queued, []) ++ [text]))}
  end

  def handle_call({:prompt, text, pictures}, _from, %{status: :idle} = state) do
    {:reply, :ok, start_prompt(state, text, fit_pictures(state, pictures))}
  end

  # While a prompt runs they wait with its text: for the batch's results,
  # or for the next prompt if the model answers first.
  def handle_call({:prompt, text, pictures}, from, state) do
    taken = fit_pictures(state, pictures)
    labelled = for {name, part} <- taken, do: {user_label(name), part}
    state = Map.update(state, :pending_images, labelled, &(&1 ++ labelled))
    handle_call({:prompt, with_names(text, taken)}, from, state)
  end

  def handle_call(:interrupt, _from, %{model_task: %Task{} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    broadcast(state, {:turn_end, %{turn: state.turn, finish_reason: "interrupted"}})
    note(state, :info, "Stopped. The partial response was discarded.")
    {:reply, :ok, finish(%{state | model_task: nil}, :interrupted)}
  end

  def handle_call(:interrupt, _from, %{status: :tools} = state) do
    tools =
      state.tools
      |> Enum.sort_by(fn {_ref, tool} -> tool.index end)
      |> Map.new(fn
        {ref, %{result: nil} = tool} ->
          if tool.task do
            # A shutdown rather than a kill, so linked helpers such as
            # Dune's sandbox exit quietly instead of logging a crash.
            Task.shutdown(tool.task)
          else
            # A call that never started still starts and ends, so every
            # tool_end has its tool_start.
            broadcast(state, {:tool_start, Map.merge(tool.call, %{status: :running, pid: nil})})
          end

          broadcast(
            state,
            {:tool_end, Map.merge(tool.call, %{status: :error, result: "Cancelled.", ms: nil})}
          )

          {ref, %{tool | result: "Cancelled by the user."}}

        finished ->
          finished
      end)

    # A cancelled call failed, as far as a later summary goes.
    cancelled =
      for {_ref, %{result: nil} = tool} <- state.tools,
          into: Map.get(state, :facts, %{}),
          do: {tool.call.id, %{status: :error, calls: []}}

    state = append_tool_results(%{state | tools: tools} |> Map.put(:facts, cancelled))
    note(state, :info, "Stopped. The running tools were cancelled.")
    {:reply, :ok, finish(state, :interrupted)}
  end

  def handle_call(:interrupt, _from, state), do: {:reply, {:error, :idle}, state}

  def handle_call(:reset, _from, %{status: :idle} = state) do
    broadcast(state, {:context, 0})
    if state.store, do: :ets.delete(state.store, :resumed_results)

    state =
      state
      |> Map.merge(%{
        compaction: nil,
        facts: %{},
        last_prompt_tokens: nil,
        last_estimate: nil,
        pending_jobs: [],
        carry: []
      })
      |> put_messages([])

    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call(:compact, _from, %{status: :idle} = state) do
    case compact_messages(state, :manual) do
      {:ok, state, info} -> {:reply, {:ok, info}, state}
      :keep -> {:reply, {:error, :nothing}, state}
    end
  end

  def handle_call(:compact, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call({:configure, settings}, _from, state) do
    case apply_settings(state, settings) do
      {:ok, state} ->
        # The user's change ends the model's own.
        state =
          if Keyword.has_key?(settings, :effort) or Keyword.has_key?(settings, :thinking),
            do: Map.put(state, :think, nil),
            else: state

        broadcast(state, {:settings, public_settings(state)})
        {:reply, {:ok, public_settings(state)}, state}

      {:error, message} ->
        {:reply, {:error, message}, state}
    end
  end

  def handle_call(:settings, _from, state), do: {:reply, public_settings(state), state}

  def handle_call({:attach_image, path, part}, _from, state) do
    images = Map.get(state, :pending_images, [])

    if length(images) >= Limits.images_per_call() do
      {:reply, {:error, "At most #{Limits.images_per_call()} pictures go with one model call."},
       state}
    else
      note(state, :info, "The model looks at #{path}.")
      label = ~s|[Visor: the picture V.image("#{path}") showed.]|
      {:reply, :ok, Map.put(state, :pending_images, images ++ [{label, part}])}
    end
  end

  def handle_call(:last_script, _from, state) do
    facts = Map.get(state, :facts, %{})

    code =
      state.messages
      |> Enum.flat_map(fn message -> message["tool_calls"] || [] end)
      |> Enum.filter(&match?(%{status: :ok}, facts[&1["id"]]))
      |> List.last()
      |> then(&(&1 && Tools.script(get_in(&1, ["function", "arguments"]))))

    {:reply, code, state}
  end

  def handle_call(:allowance, _from, state) do
    spent = spent(state)
    limits = limits(state)

    {:reply,
     %{
       prompt: limits.prompt - spent.prompt,
       session: limits.session - spent.session,
       tokens: limits.tokens - spent.tokens
     }, state}
  end

  def handle_call({:resume, from}, _from, %{status: :idle} = state) do
    with dir when is_binary(dir) <- Visor.SessionLog.dir() || {:error, "Session logging is off."},
         file when is_binary(file) <-
           Visor.SessionLog.Reader.find(dir, from) ||
             {:error, "There is no session log for #{from}."},
         events = Visor.SessionLog.Reader.read(file),
         {:ok, body} <- Visor.SessionLog.Reader.request(events, :last) do
      messages =
        (Enum.reject(body["messages"], &(&1["role"] == "system")) ++ last_answer(events))
        |> Enum.map(&Visor.Content.restore_omitted/1)

      {messages, _repaired} = Repair.messages(messages, %{}, @missing)

      state =
        state
        |> Map.merge(%{
          compaction: nil,
          facts: logged_facts(events),
          carry: logged_carry(events),
          pending_jobs: [],
          pending_texts: [],
          think: nil,
          compact_request: nil,
          last_prompt_tokens: nil,
          last_estimate: nil
        })
        |> put_messages(messages)

      if state.store, do: :ets.insert(state.store, {:resumed_results, logged_results(events)})
      broadcast(state, {:context, length(messages)})
      broadcast(state, {:resumed, %{from: from, messages: length(messages)}})
      {:reply, {:ok, length(messages)}, state}
    else
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:resume, _from}, _caller, state),
    do: {:reply, {:error, "Stop the running prompt before resuming another session."}, state}

  def handle_call({:adopt, owner}, _from, state) do
    cond do
      Map.get(state, :depth, 0) > 0 ->
        {:reply, {:error, :sub_agent}, state}

      state.owner_ref != nil ->
        {:reply, {:error, :in_use}, state}

      true ->
        if timer = Map.get(state, :grace_timer), do: Process.cancel_timer(timer)
        state = Map.merge(state, %{owner_ref: Process.monitor(owner), grace_timer: nil})
        broadcast(state, {:reattached, %{owner: owner, messages: length(state.messages)}})
        {:reply, {:ok, public_settings(state)}, state}
    end
  end

  def handle_call({:carry, change}, _from, state) do
    items = Map.get(state, :carry, [])

    result =
      case change do
        :read -> {:ok, items}
        :clear -> {:ok, []}
        {:remove, item} -> {:ok, List.delete(items, item)}
        {:add, item} -> add_carry(items, item)
      end

    case result do
      {:ok, ^items} ->
        {:reply, {:ok, items}, state}

      {:ok, new} ->
        broadcast(state, {:carry, new})
        {:reply, {:ok, new}, save(Map.put(state, :carry, new))}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:think, level, turns}, _from, state) when level in ~w(off low high max) do
    think = %{
      effort: if(level == "off", do: state.effort, else: level),
      thinking: level != "off",
      turns: turns
    }

    how = if level == "off", do: "no thinking", else: "#{level} effort with thinking"

    span =
      if turns,
        do: "the next #{Visor.Format.count(turns, "model call")}",
        else: "the rest of this prompt"

    note(state, :info, "The model set #{how} for #{span}.")
    state = save(Map.put(state, :think, think))
    broadcast(state, {:settings, public_settings(state)})
    {:reply, {:ok, public_settings(state)}, state}
  end

  def handle_call({:think, level, _turns}, _from, state),
    do: {:reply, {:error, "The level is off, low, high or max, not #{inspect(level)}."}, state}

  def handle_call({:request_compaction, reason}, _from, state) do
    {:reply, :ok, save(Map.put(state, :compact_request, reason))}
  end

  def handle_call(:context, _from, state) do
    info = Model.current().info()
    # Nil before the first request, and after a reset or a resume.
    tokens = round((Map.get(state, :last_estimate) || 0) * Map.get(state, :token_scale, 1.0))
    threshold = threshold(info)
    share = if threshold > 0, do: tokens / threshold, else: 0.0

    band =
      cond do
        share >= 0.8 -> :urgent
        share >= 0.6 -> :warn
        true -> :ok
      end

    {:reply,
     %{
       tokens: tokens,
       threshold: threshold,
       window: info[:context_window],
       share: Float.round(share, 3),
       band: band,
       carry: Map.get(state, :carry, [])
     }, state}
  end

  @impl true
  def handle_cast({:review, text, wake}, state) do
    state =
      state
      |> Map.update(:pending_texts, [text], &(&1 ++ [text]))
      |> Map.put(:wake_texts, Map.get(state, :wake_texts, false) or wake)

    {:noreply, schedule_wake(state)}
  end

  def handle_cast({:spent, cost, tokens}, state), do: {:noreply, spend(state, cost, tokens)}

  def handle_cast({:job_event, job_id}, state) do
    pending = Map.get(state, :pending_jobs, [])
    pending = if job_id in pending, do: pending, else: pending ++ [job_id]
    {:noreply, schedule_wake(Map.put(state, :pending_jobs, pending))}
  end

  @impl true
  def handle_info({ref, result}, %{model_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Visor.ModelHealth.record_result(result)
    {:noreply, handle_model_result(result, %{state | model_task: nil})}
  end

  def handle_info({ref, result}, state) when is_map_key(state.tools, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_tool(state, ref, result)}
  end

  # A console's page that closes or reloads leaves its session for
  # Visor.Limits.session_grace_ms/0, for the page to come back to (see
  # adopt/2); a sub-agent goes with its job.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    grace = Limits.session_grace_ms()

    if Map.get(state, :depth, 0) > 0 or grace == 0 do
      {:stop, :normal, state}
    else
      timer = Process.send_after(self(), :grace_over, grace)
      {:noreply, Map.merge(state, %{owner_ref: nil, grace_timer: timer})}
    end
  end

  def handle_info(:grace_over, %{owner_ref: nil} = state), do: {:stop, :normal, state}
  def handle_info(:grace_over, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{model_task: %Task{ref: ref}} = state) do
    Visor.ModelHealth.record(:error)
    broadcast(state, {:turn_end, %{turn: state.turn, finish_reason: "crashed"}})
    note(state, :error, "The model call crashed: #{Exception.format_exit(reason)}")
    {:noreply, finish(%{state | model_task: nil}, :model_crashed)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.tools, ref) do
    {:noreply, finish_tool(state, ref, {:error, "The tool crashed: #{exit_text(reason)}", []})}
  end

  # A task still running at its deadline is stopped. One that finished
  # just before has its result used; any other deadline is stale.
  def handle_info({:deadline, ref}, %{model_task: %Task{ref: ref} = task} = state) do
    case Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        Visor.ModelHealth.record_result(result)
        {:noreply, handle_model_result(result, %{state | model_task: nil})}

      _stopped ->
        # A call that hangs is the provider failing as much as one that errs.
        Visor.ModelHealth.record(:error)
        minutes = div(Limits.model_deadline_ms(), 60_000)
        broadcast(state, {:turn_end, %{turn: state.turn, finish_reason: "timeout"}})

        note(
          state,
          :error,
          "The model call was still running after #{minutes} min, so it was stopped."
        )

        {:noreply, finish(%{state | model_task: nil}, :model_error)}
    end
  end

  # A shutdown rather than a kill, as for an interrupt, so Dune's sandbox
  # exits quietly.
  def handle_info({:deadline, ref}, state) when is_map_key(state.tools, ref) do
    result =
      case Task.shutdown(state.tools[ref].task) do
        {:ok, result} ->
          result

        _stopped ->
          deadline = Map.get(state.tools[ref], :deadline, Limits.tool_deadline_ms())
          {:error, "Stopped: the script was still running after #{div(deadline, 1000)} s.", []}
      end

    {:noreply, finish_tool(state, ref, result)}
  end

  # The batch timer's wake, tagged so a timer armed again (see
  # schedule_wake/1) leaves only one to act on.
  def handle_info({:wake, ref}, state) do
    case Map.get(state, :wake_timer) do
      {^ref, _timer} -> wake(Map.put(state, :wake_timer, nil))
      _stale -> {:noreply, state}
    end
  end

  # A timer armed before wakes were tagged.
  def handle_info(:wake, state), do: wake(Map.put(state, :wake_timer, nil))

  def handle_info(_message, state), do: {:noreply, state}

  defp wake(state) do
    # Read once: a job that ended between two reads would be counted as
    # another kind than the one allowed.
    kind = wake_kind(state)

    if state.status == :idle and can_wake?(state, kind) do
      case take_notices(state) do
        {state, []} -> {:noreply, state}
        {state, notices} -> {:noreply, start_wake(state, notices, kind)}
      end
    else
      {:noreply, state}
    end
  end

  # The user's prompt. Pictures sent while the last one ran, which the
  # model never got (`pending_images`), come with it, and those of
  # earlier prompts are left out (retire_pictures/1).
  defp start_prompt(state, text, pictures \\ []) do
    broadcast(state, {:user, with_names(text, pictures)})
    {state, notices} = take_notices(state)
    text = Enum.join([text | notices], "\n\n")

    images =
      Map.get(state, :pending_images, []) ++
        for({name, part} <- pictures, do: {user_label(name), part})

    labels = for {label, _part} <- images, do: label
    parts = for {_label, part} <- images, do: part

    state
    |> retire_pictures()
    |> push_user(Visor.Content.with_images(Enum.join([text | labels], "\n\n"), parts))
    |> Map.merge(%{
      steps: 0,
      overflowed: false,
      repeat: nil,
      prompt_changed: MapSet.new(),
      nudged: false,
      kept: nil,
      pending_images: [],
      spent: %{spent(state) | prompt: 0.0, tokens: 0},
      parent_cap: rebase_parent_cap(state)
    })
    |> Wakes.reset()
    |> start_turn()
  end

  # A prompt of the agent's own, when background jobs ended while it was
  # idle: a fresh budget of model calls, without the user. `kind` is the
  # wakes it counts in (Visor.Agent.Wakes).
  defp start_wake(state, notices, kind) do
    text = Enum.join(notices, "\n\n")
    broadcast(state, {:wake, text})

    state
    |> retire_pictures()
    |> push_user(text)
    |> Map.merge(%{
      steps: 0,
      overflowed: false,
      repeat: nil,
      prompt_changed: MapSet.new(),
      nudged: false,
      kept: nil
    })
    |> Wakes.count(kind)
    |> start_turn()
  end

  # What the model hasn't heard of the jobs that ended, or of the lines a
  # running job's monitor holds. Taking them marks them as heard.
  defp take_notices(state) do
    notices =
      for id <- Map.get(state, :pending_jobs, []),
          job = Jobs.get(state.id, id),
          notice = Jobs.take_notice(state.id, job),
          do: notice

    texts = Map.get(state, :pending_texts, [])

    {Map.merge(state, %{pending_jobs: [], pending_texts: [], wake_texts: false}),
     notices ++ texts}
  end

  # `/jobs wake off` holds what jobs wake the agent for; a supervisor's
  # message wakes it all the same, within the same count. A wake for a
  # monitored job's lines alone has a count of its own, so a monitor
  # can't use up the wakes a job's end needs.
  defp can_wake?(state, kind) do
    (Map.get(state, :jobs_wake, true) or Map.get(state, :wake_texts, false)) and
      Wakes.allowed?(state, kind) and
      Visor.ModelHealth.open() == nil and Visor.Alarms.held() == nil
  end

  # What a wake would tell: `:monitor` when it is only running jobs' new
  # lines, `:jobs` when a job ended or a reviewer spoke.
  defp wake_kind(state) do
    ended? =
      Enum.any?(Map.get(state, :pending_jobs, []), fn id ->
        match?(%{status: status} when status != :running, Jobs.get(state.id, id))
      end)

    Wakes.kind(ended? or Map.get(state, :pending_texts, []) != [])
  end

  # Jobs that end close together wake the agent once. A timer that has
  # fired is armed again: its message may never come (dropped while Mix
  # recompiled this module), and no wake would start for the rest of the
  # session. If it does come, its ref is no longer the one armed.
  defp schedule_wake(state) do
    waiting? = Map.get(state, :pending_jobs, []) != [] or Map.get(state, :wake_texts, false)

    if state.status == :idle and waiting? and not wake_armed?(state) and
         can_wake?(state, wake_kind(state)) do
      ref = make_ref()
      timer = Process.send_after(self(), {:wake, ref}, Limits.job_wake_batch_ms())
      Map.put(state, :wake_timer, {ref, timer})
    else
      state
    end
  end

  defp wake_armed?(state) do
    case Map.get(state, :wake_timer) do
      nil -> false
      {_ref, timer} -> Process.read_timer(timer) != false
      # Armed before wakes were tagged.
      timer -> Process.read_timer(timer) != false
    end
  end

  # Before each model call: a prompt or session past its spending limit
  # (BeamAgent's guardrails, Vibe's budget) makes no more.
  defp start_turn(state) do
    {limits, state} = budget_limits(state)

    case over_budget(state, limits) do
      nil ->
        call_model(state)

      text ->
        note(state, :error, text)
        finish(state, :budget)
    end
  end

  defp call_model(state) do
    state = state |> repair(:request, %{}) |> maybe_compact()
    provider = Model.current()
    info = provider.info()
    turn = state.turn + 1
    id = state.id
    messages = surface(state)
    {effort, thinking, state} = settings_for_turn(state)

    # The last call keeps the tools in the request, so the provider's cache
    # still covers it, but may not call them.
    request = %{
      system: Map.get(state, :system, @system),
      messages: messages,
      tools: Tools.definitions(),
      tool_choice: if(last_step?(state, state.steps + 1), do: "none", else: "auto"),
      effort: effort,
      thinking: thinking
    }

    # The request and response as sent and received go to the session
    # log; the console shows the snapshots.
    emit = fn
      {:request, wire} -> broadcast(id, {:wire_request, turn, wire})
      {:response, wire} -> broadcast(id, {:wire_response, turn, wire})
      snapshot -> broadcast(id, {:stream, turn, snapshot})
    end

    task =
      Harness.async(state.tasks, "model turn #{turn}", fn -> provider.stream(request, emit) end)

    Process.send_after(self(), {:deadline, task.ref}, Limits.model_deadline_ms())

    broadcast(
      state,
      {:turn_start,
       %{
         turn: turn,
         step: state.steps + 1,
         max_steps: max_steps(state),
         provider: info,
         effort: effort,
         thinking: thinking,
         messages: length(messages),
         pid: task.pid
       }}
    )

    broadcast(state, {:request, turn, request_preview(request, info)})
    state = Map.put(state, :last_estimate, fixed_estimate() + estimate(messages))
    set_status(%{state | turn: turn, steps: state.steps + 1, model_task: task}, :streaming)
  end

  defp handle_model_result({:ok, result}, state) do
    broadcast(
      state,
      {:turn_end,
       %{
         turn: state.turn,
         finish_reason: result.finish_reason,
         usage: result.usage,
         model: result.model,
         chunks: result.chunks,
         ttft_ms: result.ttft_ms,
         ms: result.ms,
         final: %{
           reasoning: result.message["reasoning_content"],
           content: result.message["content"],
           tool_calls: result.tool_calls
         }
       }}
    )

    if warning = cache_warning(state.last_prompt_tokens, result.usage),
      do: note(state, :info, warning)

    state =
      %{state | last_prompt_tokens: prompt_tokens(result.usage, state.last_prompt_tokens)}
      |> calibrate(result.usage)
      |> spend_usage(result.usage)

    max = max_steps(state)

    state =
      case {result.finish_reason, result.tool_calls} do
        {"tool_calls", [_ | _]} when state.steps >= max ->
          note(state, :error, "Stopped after #{max} model calls for one prompt.")
          state |> append(Map.delete(result.message, "tool_calls")) |> finish(:step_limit)

        {"tool_calls", [_ | _] = calls} ->
          state |> append(result.message) |> run_tools(calls)

        {"stop", _calls} when state.steps >= max ->
          state |> append(result.message) |> finish(:step_limit)

        {"stop", _calls} ->
          state |> append(result.message) |> answered()

        {"length", _calls} ->
          note(
            state,
            :error,
            "The response hit the max_tokens limit and was cut off. Its tool calls were not run."
          )

          state |> append(Map.delete(result.message, "tool_calls")) |> finish(:max_tokens)

        {reason, _calls} ->
          note(
            state,
            :error,
            "The model stopped without finishing (finish_reason: #{reason || "none"})."
          )

          finish(state, :unfinished)
      end

    # The reply, when kept, is now part of the conversation.
    broadcast(state, {:context, length(surface(state))})
    state
  end

  # The provider rejected the request as too large: longer than its
  # window, or (HTTP 413) over the size it takes. Leave out the pictures
  # the model has already answered (compaction keeps the recent part as
  # it was, pictures and all), compact under 90% of what was sent, and try
  # once more if either made the request smaller.
  defp handle_model_result({:error, :context_overflow, message}, state) do
    broadcast(state, {:turn_end, %{turn: state.turn, finish_reason: "error"}})
    sent = round(Map.get(state, :last_estimate, 0) * Map.get(state, :token_scale, 1.0))
    window = max(floor(sent * 0.9), 1)

    with false <- Map.get(state, :overflowed, false),
         {:ok, state, done} <- smaller(Map.put(state, :overflowed, true), window) do
      note(
        state,
        :info,
        "The request was too large for the model, so #{done} and the call made again."
      )

      start_turn(state)
    else
      _ ->
        note(state, :error, message)
        finish(state, :model_error)
    end
  end

  # A request the provider refused as malformed fails the prompt as any
  # error does, though it tells nothing of the provider's health.
  defp handle_model_result({:error, :rejected, message}, state),
    do: handle_model_result({:error, message}, state)

  defp handle_model_result({:error, message}, state) do
    broadcast(state, {:turn_end, %{turn: state.turn, finish_reason: "error"}})
    note(state, :error, message)
    finish(state, :model_error)
  end

  # The request made smaller after an overflow, and what was done, or
  # :keep when nothing could be.
  defp smaller(state, window) do
    retired = retire_pictures(state)
    pictures? = retired.messages != state.messages

    case compact_messages(retired, :overflow, window) do
      {:ok, state, _info} when pictures? ->
        {:ok, state, "the pictures it had answered were left out, the conversation compacted"}

      {:ok, state, _info} ->
        {:ok, state, "the conversation was compacted"}

      :keep when pictures? ->
        {:ok, retired, "the pictures it had answered were left out"}

      :keep ->
        :keep
    end
  end

  @doc false
  # A note when a request read much less of its prompt from the
  # provider's cache than the previous request sent. The conversation only
  # grows at its end, so the cache should cover at least that much; less
  # means its start changed (or the cache wasn't ready yet).
  def cache_warning(previous, usage) when is_integer(previous) and previous >= 4096 do
    case Usage.from(usage) do
      %Usage{cached: hit, prompt: prompt} when is_integer(hit) and hit < previous * 0.8 ->
        "The cache served #{hit} of this request's #{prompt} prompt tokens, but the " <>
          "previous request sent #{previous}. The start of the conversation changed, or the " <>
          "cache wasn't ready yet."

      _enough ->
        nil
    end
  end

  def cache_warning(_previous, _usage), do: nil

  defp prompt_tokens(usage, previous) do
    case Usage.from(usage) do
      %Usage{prompt: tokens} when is_integer(tokens) -> tokens
      _unknown -> previous
    end
  end

  # How many provider tokens an estimated token is, from the request just
  # answered. Estimates come from term sizes, which undercount tokens.
  defp calibrate(state, usage) do
    with %Usage{prompt: tokens} when is_integer(tokens) <- Usage.from(usage),
         estimate when is_integer(estimate) and estimate > 0 <- Map.get(state, :last_estimate) do
      Map.put(state, :token_scale, max(tokens / estimate, 1.0))
    else
      _unknown -> state
    end
  end

  ## Compaction

  # A compaction the model asked for waits until its prompt has ended, as
  # pi-fabric's waits for the agent to settle: at the first model call of
  # the next prompt (or wake), what came before that prompt is summed up
  # and the prompt stays as it was. Made mid-prompt, it would take the
  # request being worked on with it. Otherwise only past the threshold.
  defp maybe_compact(state) do
    case Map.get(state, :compact_request) do
      request when is_binary(request) and state.steps == 0 ->
        state = Map.merge(state, %{compact_request: nil, requested: request})
        prompt = length(state.messages) - 1

        case compact_messages(state, :requested, nil, prompt) do
          {:ok, state, _info} ->
            Map.delete(state, :requested)

          :keep ->
            note(
              state,
              :info,
              "The compaction a script asked for (#{request}) wasn't made: there isn't enough " <>
                "before this prompt to sum up yet."
            )

            state |> Map.delete(:requested) |> save()
        end

      _none_or_waiting ->
        case compact_messages(state, :threshold) do
          {:ok, state, _info} -> state
          :keep -> state
        end
    end
  end

  # This model call's effort and thinking: the model's own while it lasts,
  # else the user's. A count of calls runs down with each.
  defp settings_for_turn(state) do
    case Map.get(state, :think) do
      nil ->
        {state.effort, state.thinking, state}

      %{turns: 1} = think ->
        {think.effort, think.thinking, Map.put(state, :think, nil)}

      %{turns: turns} = think when is_integer(turns) ->
        {think.effort, think.thinking, Map.put(state, :think, %{think | turns: turns - 1})}

      think ->
        {think.effort, think.thinking, state}
    end
  end

  defp add_carry(items, item) do
    cond do
      item in items ->
        {:ok, items}

      String.trim(item) == "" ->
        {:error, "A carried item can't be empty."}

      String.length(item) > Limits.carry_chars() ->
        {:error, "A carried item is at most #{Limits.carry_chars()} characters."}

      length(items) >= Limits.carry_items() ->
        {:error,
         "The summary carries at most #{Limits.carry_items()} items. Remove one first, " <>
           ~s|with V.carry(remove: "...").|}

      true ->
        {:ok, items ++ [item]}
    end
  end

  # Compacts the conversation: past the threshold (`:threshold`), or now
  # (`:manual`, `:overflow`, `:requested`), keeping the messages from
  # `keep_from` as they are. The cache misses once after a compaction, so
  # the next request is not compared with the last.
  defp compact_messages(state, reason, window \\ nil, keep_from \\ nil) do
    provider = Model.current().info()
    current = Map.get(state, :compaction)

    result =
      Compaction.compact(
        state.messages,
        [
          compaction: current,
          facts: Map.get(state, :facts, %{}),
          fixed: fixed_estimate(),
          scale: Map.get(state, :token_scale, 1.0),
          threshold: threshold(provider),
          window: window || provider[:context_window],
          force: reason != :threshold,
          carry: Map.get(state, :carry, [])
        ] ++ if(keep_from, do: [keep_from: keep_from], else: [])
      )

    case result do
      {:ok, compaction, compacted} ->
        before = length(surface(state))
        state = state |> Map.merge(%{compaction: compaction, last_prompt_tokens: nil}) |> save()
        left = length(surface(state))

        info =
          Map.merge(compacted, %{
            turn: state.turn,
            reason: reason,
            messages_before: before,
            messages_after: left
          })

        info = if r = Map.get(state, :requested), do: Map.put(info, :request, r), else: info

        broadcast(state, {:compaction, info})
        broadcast(state, {:context, left})
        {:ok, state, info}

      :keep ->
        :keep
    end
  end

  # The context size that compacts: the provider's own setting, or
  # Visor.Limits.compact_tokens/0 kept under the window less its reserve.
  defp threshold(info) do
    case info do
      %{compact_tokens: tokens} when is_integer(tokens) ->
        tokens

      %{context_window: window} when is_integer(window) ->
        min(window - Limits.reserve_tokens(), Limits.compact_tokens())

      _unknown ->
        Limits.compact_tokens()
    end
  end

  defp surface(state), do: Compaction.surface(state.messages, Map.get(state, :compaction))

  defp fixed_estimate, do: Compaction.estimate(@system) + Compaction.estimate(Tools.definitions())

  defp estimate(messages), do: messages |> Enum.map(&Compaction.estimate/1) |> Enum.sum()

  ## Tools

  # A batch's calls run one at a time, in order: two scripts editing the
  # same file at once would each write over the other's change.
  defp run_tools(state, calls) do
    tools =
      calls
      |> Enum.with_index()
      |> Map.new(fn {call, index} ->
        {make_ref(),
         %{call: call, index: index, task: nil, started: nil, result: nil, repeat: nil}}
      end)

    set_status(start_next_tool(%{state | tools: tools}), :tools)
  end

  defp start_next_tool(state) do
    waiting = for {ref, %{task: nil, result: nil} = tool} <- state.tools, do: {ref, tool}

    case Enum.min_by(waiting, fn {_ref, tool} -> tool.index end, fn -> nil end) do
      nil ->
        state

      {ref, %{call: call} = tool} ->
        # Decoded and put right once, here: the count reads the script as it
        # runs, and the task runs this one.
        prepared = Tools.prepare(call.arguments)
        {state, count} = repeat(state, call, prepared)

        if count >= Limits.repeat_block() do
          # Not run: it still starts and ends, like a cancelled call.
          broadcast(state, {:tool_start, Map.merge(call, %{status: :running, pid: nil})})
          state = put_in(state.tools[ref].started, now())
          finish_tool(state, ref, {:error, repeat_blocked(count), []})
        else
          run_tool(state, ref, Map.merge(tool, %{repeat: count, prepared: prepared}))
        end
    end
  end

  defp run_tool(state, ref, %{call: call} = tool) do
    prepared = Map.get(tool, :prepared)
    context = %{session: state.id, call_id: call.id, prepared: prepared}
    # The prompt's variables so far, which the script continues.
    kept = Map.get(state, :kept) || Dune.Session.new()

    task =
      Harness.async(state.tasks, "tool #{call.name}", fn ->
        Tools.execute(call.name, call.arguments, context, kept)
      end)

    deadline = Limits.tool_deadline_ms(Visor.Code.timeout_ms(asked_timeout(prepared)))
    Process.send_after(self(), {:deadline, task.ref}, deadline)
    broadcast(state, {:tool_start, Map.merge(call, %{status: :running, pid: task.pid})})
    tool = Map.merge(tool, %{task: task, started: now(), deadline: deadline})
    %{state | tools: state.tools |> Map.delete(ref) |> Map.put(task.ref, tool)}
  end

  # Counts a script run again unchanged, back to back: models in a loop
  # rerun the same script and spend the prompt's model calls on it.
  # The script as it runs, after the argument repairs, as pi-fabric's
  # fingerprint is taken: a code fence or a list of lines isn't a change.
  defp repeat(state, call, prepared) do
    hash = :erlang.phash2({call.name, Tools.script_of(prepared) || call.arguments})

    count =
      case Map.get(state, :repeat) do
        {^hash, count} -> count + 1
        _other -> 1
      end

    if count >= Limits.repeat_warn() do
      broadcast(
        state,
        {:repeat, %{id: call.id, count: count, blocked: count >= Limits.repeat_block()}}
      )
    end

    {Map.put(state, :repeat, {hash, count}), count}
  end

  # The seconds a call's script asked for, if any (see Visor.Code.timeout_ms/1).
  defp asked_timeout({:ok, %{"timeout" => seconds}, _fixes}), do: seconds
  defp asked_timeout(_prepared), do: nil

  defp repeat_warning(count) do
    "[Visor: this exact script has run #{count} times in a row. At " <>
      "#{Limits.repeat_block()} in a row it is refused: change the approach, or answer with " <>
      "what you know.]"
  end

  defp repeat_blocked(count) do
    "Not run: this exact script already ran #{count - 1} times in a row, and running it " <>
      "again adds nothing. Answer with what you know, or change the script."
  end

  # A task started before a hot reload still returns {status, output}.
  defp finish_tool(state, ref, {status, output}),
    do: finish_tool(state, ref, {status, output, []})

  # The script's variables go on to the next script of the prompt, unless
  # they grew past Visor.Limits.kept_bytes/0. They aren't saved: a
  # restarted agent starts a prompt without them.
  defp finish_tool(state, ref, {status, output, facts, %Dune.Session{} = kept}) do
    {kept, output} =
      if :erlang.external_size(kept) > Limits.kept_bytes() do
        {nil,
         output <>
           "\n\n[Visor: the variables kept from script to script passed " <>
           "#{div(Limits.kept_bytes(), 1_000_000)} MB, so they were dropped; set what you " <>
           "need again.]"}
      else
        {kept, output}
      end

    state |> Map.put(:kept, kept) |> finish_tool(ref, {status, output, facts})
  end

  defp finish_tool(state, ref, {status, output, facts}) do
    tool = state.tools[ref]

    output =
      case Map.get(tool, :repeat) do
        count when is_integer(count) and count >= 1 ->
          if count >= Limits.repeat_warn(),
            do: output <> "\n\n" <> repeat_warning(count),
            else: output

        _not_counted ->
          output
      end

    broadcast(
      state,
      {:tool_end,
       Map.merge(tool.call, %{status: status, result: output, ms: now() - tool.started})}
    )

    state = put_in(state.tools[ref].result, output)
    facts = Map.put(Map.get(state, :facts, %{}), tool.call.id, %{status: status, calls: facts})
    # Saved as it comes in, so an agent that crashes later in the batch
    # still answers this call with its result.
    state = save(Map.put(state, :facts, facts))
    # What an attempt put back isn't a change.
    script_facts = facts[tool.call.id].calls
    reverted = for %{reverted: paths} <- script_facts, path <- paths, do: path

    changed = for %{changed: path} <- script_facts, path not in reverted, do: path

    state =
      Map.update(
        state,
        :prompt_changed,
        MapSet.new(changed),
        &MapSet.union(&1, MapSet.new(changed))
      )

    cond do
      Enum.any?(Map.values(state.tools), &is_nil(&1.result)) ->
        start_next_tool(state)

      true ->
        if last_step?(state, state.steps + 1) do
          note(
            state,
            :info,
            "The next model call is the last of #{max_steps(state)} for this prompt, so it runs " <>
              "without tools and reports where the work got to."
          )
        end

        state |> append_tool_results(footer(state)) |> steer() |> start_turn()
    end
  end

  # What the user sent while the batch ran reaches the model now, after its
  # results, as one user message.
  # Background jobs that ended, and monitored jobs' new lines, come after them.
  defp steer(state) do
    {state, notices} = take_notices(state)
    images = Map.get(state, :pending_images, [])

    case Map.get(state, :queued, []) ++ notices do
      [] when images == [] ->
        state

      texts ->
        shown = for {label, _part} <- images, do: label

        content =
          Visor.Content.with_images(
            Enum.join(shown ++ texts, "\n\n"),
            Enum.map(images, &elem(&1, 1))
          )

        state
        |> Map.merge(%{queued: [], pending_images: []})
        |> append(%{"role" => "user", "content" => content})
    end
  end

  # What a crashed task's exit says, without its stack frames: they are
  # the harness's, not the script's.
  defp exit_text({exception, stack}) when is_exception(exception) and is_list(stack),
    do: Exception.format_banner(:error, exception, stack)

  defp exit_text(reason), do: Exception.format_exit(reason)

  defp last_step?(state, step), do: step >= max_steps(state)

  defp max_steps(state), do: Map.get(state, :max_steps, @max_steps)

  # The reply to a log's last request, when it was an answer.
  defp last_answer(events) do
    after_request =
      events
      |> Enum.reverse()
      |> Enum.take_while(&(&1["event"] != "request"))
      |> Enum.reverse()

    case Enum.find(after_request, &(&1["event"] == "turn_end")) do
      %{"finish_reason" => "stop", "content" => content}
      when is_binary(content) and content != "" ->
        [%{"role" => "assistant", "content" => content}]

      _other ->
        []
    end
  end

  # What a log's scripts did, as the facts compaction sums up, by tool
  # call id: each call's status, and its V calls as they ended.
  # Each call's result as the model saw it, for V.recall/1 after a resume.
  defp logged_results(events) do
    for %{"event" => "tool_end", "id" => id, "result" => result} <- events,
        is_binary(result),
        into: %{},
        do: {id, result}
  end

  defp logged_facts(events) do
    statuses =
      for %{"event" => "tool_end", "id" => id, "status" => s} <- events, into: %{}, do: {id, s}

    calls =
      events
      |> Enum.filter(&(&1["event"] == "code_call" and &1["status"] in ["ok", "error"]))
      |> Enum.group_by(& &1["call_id"], &logged_call/1)

    Map.new(statuses, fn {id, status} ->
      {id, %{status: if(status == "ok", do: :ok, else: :error), calls: Map.get(calls, id, [])}}
    end)
  end

  defp logged_call(line) do
    name =
      try do
        line["name"] && String.to_existing_atom(line["name"])
      rescue
        ArgumentError -> nil
      end

    %{
      name: name,
      text: line["text"],
      status: if(line["status"] == "ok", do: :ok, else: :error),
      changed: line["changed"],
      ran: line["ran"],
      exit: line["exit"],
      error: line["error"]
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp logged_carry(events) do
    case for(%{"event" => "carry", "items" => items} <- events, do: items) |> List.last() do
      nil -> []
      items -> items
    end
  end

  # A sub-agent's system prompt says what it is for (V.agent/2).
  defp system_prompt(nil, _read_only), do: @system

  defp system_prompt(role, read_only) do
    @system <>
      "\nYou are a sub-agent: another Visor agent gave you its task as the user's message, " <>
      "and only your final answer goes back to it. Do the task, then answer briefly with " <>
      "what it needs: results, file paths, what failed. Your role: " <>
      role <>
      if(read_only,
        do:
          "\nYou only read, as a council member: V.write, V.edit, V.sh, V.check and V.save " <>
            "are refused, so read and search the project, then answer.",
        else: ""
      )
  end

  # The project's own instructions for agents, AGENTS.md or else
  # CLAUDE.md, as Codex and Claude Code read them. Read once, when the
  # session starts: the system prompt, and the provider's cache of it,
  # stays the same all session, so a change to the file shows in the
  # next session. At most Visor.Limits.rules_bytes/0 of it, cut at a line;
  # the model reads the rest itself.
  defp project_rules do
    with name when is_binary(name) <-
           Enum.find(["AGENTS.md", "CLAUDE.md"], &match?({:ok, true}, Tools.exists(&1))),
         {:ok, text} <- Tools.read(name) do
      max = Limits.rules_bytes()

      {kept, note} =
        if byte_size(text) > max do
          cut = binary_part(text, 0, max)
          [_partial | lines] = cut |> String.split("\n") |> Enum.reverse()

          {lines |> Enum.reverse() |> Enum.join("\n"),
           "\n\n[Visor: the first #{Visor.Format.number(max)} of " <>
             "#{Visor.Format.number(byte_size(text))} " <>
             "bytes; V.read(\"#{name}\") has the rest.]"}
        else
          {text, ""}
        end

      "\n\nThe project's #{name}, its instructions for working on it:\n\n" <>
        String.trim(kept) <> note
    else
      _none -> ""
    end
  end

  # What goes after a batch's last result: the calls left, and the jobs
  # still running, so the model knows it will hear of them.
  defp footer(state) do
    case Enum.reject([kept_values(state), steps_left(state), running_jobs(state)], &is_nil/1) do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  # The variables the next script starts with, so the model knows what it
  # holds; they last until the prompt ends.
  defp kept_values(state) do
    case Map.get(state, :kept) && Visor.Code.kept(state.kept) do
      [_ | _] = kept ->
        {shown, rest} = Enum.split(Enum.sort(kept), 12)
        more = if rest == [], do: "", else: " and #{length(rest)} more"
        names = Enum.map_join(shown, ", ", fn {name, value} -> "#{name} (#{describe(value)})" end)
        "[Visor: kept for this prompt's next scripts: #{names}#{more}.]"

      _none ->
        nil
    end
  end

  defp describe(value) when is_binary(value),
    do: "string, #{Visor.Format.short(byte_size(value))} B"

  defp describe(value) when is_list(value), do: "list of #{length(value)}"
  defp describe(%module{}), do: inspect(module)
  defp describe(value) when is_map(value), do: "map of #{map_size(value)}"
  defp describe(value) when is_integer(value), do: "integer"
  defp describe(value) when is_float(value), do: "float"
  defp describe(value) when is_atom(value), do: inspect(value)
  defp describe(value) when is_tuple(value), do: "tuple of #{tuple_size(value)}"
  defp describe(_value), do: "value"

  defp running_jobs(state) do
    case Jobs.running(state.id) do
      [] ->
        nil

      jobs ->
        shown = jobs |> Enum.take(8) |> Enum.map_join(", ", &running_job/1)
        more = if length(jobs) > 8, do: " and #{length(jobs) - 8} more", else: ""

        "[Visor: running in the background: #{shown}#{more}. Don't poll them: you'll hear " <>
          "when each ends, after your next tool calls or as a message of its own.]"
    end
  end

  defp running_job(job) do
    case Map.get(job, :monitor) do
      nil -> "#{job.id} (#{Jobs.label(job)})"
      true -> "#{job.id} (#{Jobs.label(job)}; you hear of its lines)"
      text -> "#{job.id} (#{Jobs.label(job)}; you hear of its lines with #{inspect(text)})"
    end
  end

  # What the model is told about its remaining calls, after the last tool
  # result. Only new messages carry it, so the cached prefix stays the same.
  defp steps_left(%{steps: steps} = state) do
    case max_steps(state) - steps do
      1 ->
        "[Visor: this is the last model call for this prompt, and it can't run tools. " <>
          "Reply to the user: what is done, what isn't, what you suspect is wrong and " <>
          "what you'd do next. They can say \"continue\" for #{max_steps(state)} more calls.]"

      left when left <= @warn_steps ->
        "[Visor: #{left} model calls left for this prompt, this one included; the last " <>
          "can't run tools. Finish what you're on, or wrap up and leave the last call to " <>
          "report.]"

      _plenty ->
        nil
    end
  end

  ## The conversation

  defp append_tool_results(state, footer \\ nil) do
    tools = state.tools |> Map.values() |> Enum.sort_by(& &1.index)
    last = length(tools) - 1

    messages =
      for {tool, index} <- Enum.with_index(tools) do
        content =
          if footer && index == last, do: tool.result <> "\n\n" <> footer, else: tool.result

        %{"role" => "tool", "tool_call_id" => tool.call.id, "content" => content}
      end

    put_messages(%{state | tools: %{}}, state.messages ++ messages)
  end

  # After an interrupted model call the last message is an unanswered user
  # prompt; fold the new prompt into it instead of sending two in a row.
  # Not into one a compaction summarized, which the model no longer sees.
  defp push_user(%{messages: messages} = state, text) do
    from =
      case Map.get(state, :compaction) do
        %{from: from} -> from
        nil -> 0
      end

    case List.last(messages) do
      %{"role" => "user", "content" => previous} when length(messages) > from ->
        message = %{"role" => "user", "content" => Visor.Content.append(previous, text)}
        put_messages(state, List.replace_at(messages, -1, message))

      _ ->
        append(state, %{"role" => "user", "content" => text})
    end
  end

  defp append(state, message), do: put_messages(state, state.messages ++ [message])

  defp put_messages(state, messages), do: save(%{state | messages: messages})

  # Keeps the conversation in the session's table, so a restart keeps it.
  defp save(state) do
    if store = Map.get(state, :store) do
      conversation = %{
        messages: state.messages,
        compaction: Map.get(state, :compaction),
        facts: Map.get(state, :facts, %{}),
        queued: Map.get(state, :queued, []),
        # Pictures sent with what is queued, or asked for by the batch.
        pending_images: Map.get(state, :pending_images, []),
        carry: Map.get(state, :carry, []),
        think: Map.get(state, :think),
        compact_request: Map.get(state, :compact_request),
        # The running batch's results so far, by call id.
        batch:
          for(
            {_ref, %{result: result, call: call}} <- state.tools,
            result,
            into: %{},
            do: {call.id, result}
          )
      }

      :ets.insert(store, {:conversation, conversation})
    end

    state
  end

  # A restarted agent carries on with the conversation its last run kept.
  # A batch it was running when it went down is answered: with the
  # results that had come in, and the rest as having none (@restarted).
  defp restore(%{store: nil} = state), do: state

  defp restore(state) do
    case :ets.lookup(state.store, :conversation) do
      [{:conversation, conversation}] ->
        state
        |> struct(Map.delete(conversation, :batch))
        |> Map.put(:pending_images, Map.get(conversation, :pending_images, []))
        |> repair(:restart, Map.get(conversation, :batch, %{}))
        |> restore_jobs()

      [] ->
        state
    end
  end

  # Jobs that ended while no agent heard of them reach the model with the
  # next prompt, as after a failed call.
  defp restore_jobs(state) do
    case for(job <- Jobs.list(state.id), job.status != :running, not job.acknowledged, do: job.id) do
      [] -> state
      pending -> state |> Map.put(:pending_jobs, pending) |> Wakes.hold()
    end
  end

  defp repair(state, reason, results) do
    missing = if reason == :restart, do: @restarted, else: @missing

    case Repair.messages(state.messages, results, missing) do
      {_messages, nil} ->
        state

      {messages, info} ->
        broadcast(state, {:repair, Map.put(info, :reason, reason)})
        put_messages(state, messages)
    end
  end

  defp apply_settings(state, settings) do
    Enum.reduce_while(settings, {:ok, state}, fn
      {:effort, effort}, {:ok, state} when effort in @efforts ->
        {:cont, {:ok, %{state | effort: effort}}}

      {:effort, effort}, _ ->
        {:halt, {:error, "Effort must be one of #{Enum.join(@efforts, ", ")}, not #{effort}."}}

      {:thinking, thinking}, {:ok, state} when is_boolean(thinking) ->
        {:cont, {:ok, %{state | thinking: thinking}}}

      {:jobs_wake, wake}, {:ok, state} when is_boolean(wake) ->
        {:cont, {:ok, schedule_wake(Map.put(state, :jobs_wake, wake))}}

      {:budget, {scope, dollars}}, {:ok, state}
      when scope in [:prompt, :session] and is_number(dollars) and dollars > 0 ->
        limits = Map.put(limits(state), scope, dollars / 1)
        {:cont, {:ok, Map.put(state, :limits, limits)}}

      {:budget, _other}, _ ->
        {:halt, {:error, "A limit is prompt or session and a number of dollars above 0."}}
    end)
  end

  defp public_settings(state) do
    %{
      effort: state.effort,
      thinking: state.thinking,
      jobs_wake: Map.get(state, :jobs_wake, true),
      think: Map.get(state, :think),
      spent: spent(state),
      limits: limits(state),
      status: state.status,
      messages: length(surface(state)),
      provider: Model.current().info()
    }
  end

  # Ends the running prompt: the reply came, or why it didn't. What the user
  # sent while it ran and the model never saw is the next prompt, unless
  # the user stopped this one or the model call failed, which the next
  # would likely do too.
  # The model answered. Files the prompt changed that no passing check
  # has covered since get it one reminder while two calls are left (one
  # to check, one to answer), as BeamAgent's verifier catches a run that
  # claims success without the tools it needed; otherwise the prompt ends
  # with them as `unchecked`.
  defp answered(state) do
    unchecked = unchecked(state)

    if unchecked != [] and not Map.get(state, :nudged, false) and
         state.steps <= max_steps(state) - 2 do
      note(
        state,
        :info,
        "Visor asked the model to check #{paths_text(unchecked)} before it answers."
      )

      state
      |> Map.put(:nudged, true)
      |> push_user(
        "[Visor: #{paths_text(unchecked)} changed in this prompt, and no passing check has " <>
          "covered #{if length(unchecked) == 1, do: "it", else: "them"} since. Run V.check() " <>
          "before you answer, or say in a line why it isn't needed.]"
      )
      |> start_turn()
    else
      finish(state, :answered)
    end
  end

  defp user_label(name), do: "[The user's picture: #{name}]"

  # The user's pictures, kept in the session's table by name (the newest
  # Visor.Limits.pictures_kept/0) for V.image("picture:NAME") once their
  # prompt has ended (retire_pictures/1). A name used before gets a
  # number: pasted pictures are all called image.png.
  # The pictures that fit in the next model call with those already
  # waiting (Visor.Limits.images_per_call/0), kept for V.image; the rest
  # are left out, and the console says so.
  defp fit_pictures(state, pictures) do
    room = max(Limits.images_per_call() - length(Map.get(state, :pending_images, [])), 0)
    {taken, left_out} = Enum.split(pictures, room)

    if left_out != [] do
      names = Enum.map_join(left_out, ", ", &elem(&1, 0))

      note(
        state,
        :error,
        "At most #{Limits.images_per_call()} pictures go with one model call, so " <>
          "#{names} #{if length(left_out) == 1, do: "was", else: "were"} left out."
      )
    end

    keep_pictures(state, taken)
  end

  defp keep_pictures(%{store: nil}, pictures), do: pictures
  defp keep_pictures(_state, []), do: []

  defp keep_pictures(state, pictures) do
    {kept, names} =
      case :ets.lookup(state.store, :pictures) do
        [{:pictures, kept, names}] -> {kept, names}
        [] -> {[], MapSet.new()}
      end

    {named, names} =
      Enum.map_reduce(pictures, names, fn {name, part}, names ->
        name = unique_name(name, names)
        {{name, part}, MapSet.put(names, name)}
      end)

    :ets.insert(state.store, {:pictures, trim_kept(kept ++ named), names})
    named
  end

  # The newest, within Visor.Limits.pictures_kept/0 and
  # pictures_kept_bytes/0. A part kept is the conversation's own binary,
  # shared, until its prompt ends and the conversation leaves it out.
  defp trim_kept([_oldest | newer] = kept) do
    bytes = kept |> Enum.map(fn {_name, part} -> Visor.Content.bytes(part) end) |> Enum.sum()

    if length(kept) > Limits.pictures_kept() or bytes > Limits.pictures_kept_bytes(),
      do: trim_kept(newer),
      else: kept
  end

  defp trim_kept([]), do: []

  defp unique_name(name, names, n \\ 1) do
    candidate = if n == 1, do: name, else: "#{Path.rootname(name)}-#{n}#{Path.extname(name)}"
    if MapSet.member?(names, candidate), do: unique_name(name, names, n + 1), else: candidate
  end

  @picture_left_out "[A picture left out once its prompt ended. V.image shows it again: by " <>
                      "its path in the project, or as \"picture:NAME\" for one the user sent.]"

  # A picture goes with the model calls of the prompt it came with. From
  # the next prompt on it is left out, or every request would carry again
  # the megabytes of each picture the model has already answered about.
  # Done as a prompt starts, so what the provider has cached changes once,
  # not at every call. One the model hasn't answered yet (in the prompt a
  # failed call left unanswered) stays.
  defp retire_pictures(%{messages: messages} = state) do
    answered =
      messages
      |> Enum.with_index()
      |> Enum.reduce(nil, fn {message, i}, last ->
        if message["role"] == "assistant", do: i, else: last
      end)

    {messages, changed?} =
      messages
      |> Enum.with_index()
      |> Enum.map_reduce(false, fn {message, i}, changed? ->
        if answered != nil and i < answered and Visor.Content.images(message["content"]) > 0 do
          content = Visor.Content.leave_out_images(message["content"], @picture_left_out)
          {%{message | "content" => content}, true}
        else
          {message, changed?}
        end
      end)

    if changed?, do: put_messages(state, messages), else: state
  end

  # The prompt as the console shows it: its pictures by name.
  defp with_names(text, []), do: text

  defp with_names(text, pictures),
    do: Enum.join([text | for({name, _} <- pictures, do: "[picture: #{name}]")], "\n")

  ## Spending

  defp default_limits do
    %{
      prompt: Limits.prompt_cost_limit(),
      session: Limits.session_cost_limit(),
      tokens: Limits.prompt_token_limit()
    }
  end

  defp limits(state), do: Map.get(state, :limits) || default_limits()

  # This agent's limits, and a sub-agent's no more than its parent has
  # left: it asks before each model call, after its own calls' costs have
  # reached the parent (spend/3; messages between two processes keep their
  # order), so the two together stop at the parent's limit and one call
  # (proofs/budget.ts). It rises when the parent's limit does.
  #
  # The answer is kept as caps on the sub-agent's own spending. When the
  # parent doesn't answer in time (it is busy, or its session is ending),
  # the sub-agent holds to them, so to the parent's last answer less what
  # it has spent since: only what the parent and its other sub-agents
  # spent since that answer can pass the limit (the slow parent in
  # proofs/budget.ts). Before any answer it holds to the limits it started
  # with, what the parent had left then. Returns the limits, and the state
  # with the answer kept.
  defp budget_limits(state) do
    limits = limits(state)

    case Map.get(state, :budget_parent) do
      nil ->
        {limits, state}

      parent ->
        case parent_allowance(parent) do
          %{} = left ->
            spent = spent(state)

            caps = %{
              prompt: spent.prompt + left.prompt,
              session: spent.session + left.session,
              tokens: spent.tokens + left.tokens
            }

            {lowest(limits, caps), Map.put(state, :parent_cap, caps)}

          nil ->
            caps = Map.get(state, :parent_cap)
            held = lowest(limits, caps || limits)
            note(state, :info, unanswered(state, held, caps != nil))
            {held, state}
        end
    end
  end

  defp lowest(limits, caps),
    do: Map.new(limits, fn {key, limit} -> {key, min(limit, Map.fetch!(caps, key))} end)

  defp unanswered(state, held, answered?) do
    left = max(held.prompt - spent(state).prompt, 0.0)

    "Its parent session didn't say in time what it has left, so this sub-agent holds to " <>
      if(answered?, do: "its last answer", else: "what it started with") <>
      ": #{Visor.Format.dollars(left)} more for this prompt."
  end

  # A new prompt's spending starts from nothing, and so do the caps the
  # parent's last answer put on it, keeping what they left.
  defp rebase_parent_cap(state) do
    with %{} = caps <- Map.get(state, :parent_cap) do
      spent = spent(state)
      %{caps | prompt: caps.prompt - spent.prompt, tokens: caps.tokens - spent.tokens}
    end
  end

  # Briefly: a sub-agent's prompt waits for this, and its job's task
  # waits for the prompt (Agent.prompt/2's 5 s).
  defp parent_allowance(parent) do
    GenServer.call(via(parent), :allowance, 1_000)
  catch
    :exit, _reason -> nil
  end

  defp spent(state), do: Map.get(state, :spent) || %{prompt: 0.0, session: 0.0, tokens: 0}

  defp spend_usage(state, usage) do
    case Usage.from(usage) do
      nil -> state
      usage -> spend(state, usage.cost, (usage.prompt || 0) + (usage.completion || 0))
    end
  end

  # A sub-agent's spending is its parent's too, passed on as it comes, so
  # the parent has counted it when the sub-agent next asks what is left
  # (budget_limits/1).
  defp spend(state, cost, tokens) do
    spent = spent(state)
    cost = cost || 0.0
    tokens = tokens || 0

    if (parent = Map.get(state, :budget_parent)) && (cost != 0 or tokens != 0),
      do: spent(parent, cost, tokens)

    Map.put(state, :spent, %{
      spent
      | prompt: spent.prompt + cost,
        session: spent.session + cost,
        tokens: spent.tokens + tokens
    })
  end

  defp over_budget(state, limits) do
    spent = spent(state)
    dollars = &Visor.Format.dollars/1

    cond do
      Map.get(state, :budget_parent) &&
          (spent.session >= limits.session or spent.prompt >= limits.prompt) ->
        "This sub-agent has spent #{dollars.(spent.prompt)}, all its parent's limit leaves " <>
          "it, so it stops here."

      spent.session >= limits.session ->
        "This session has spent #{dollars.(spent.session)}, its limit of " <>
          "#{dollars.(limits.session)}, so no more model calls are made (/budget raises it)."

      spent.prompt >= limits.prompt ->
        "This prompt has spent #{dollars.(spent.prompt)}, its limit of " <>
          "#{dollars.(limits.prompt)}, so it stops here (/budget raises it)."

      spent.tokens >= limits.tokens ->
        "This prompt has used #{Visor.Format.number(spent.tokens)} tokens, its limit, so " <>
          "it stops here."

      true ->
        nil
    end
  end

  # Elixir files this prompt changed that no passing check has covered
  # since (see Visor.Feedback.unverified/2), in a project V.check can check.
  defp unchecked(state) do
    changed =
      state
      |> Map.get(:prompt_changed, MapSet.new())
      |> Enum.filter(&(Path.extname(&1) in ~w(.ex .exs .heex .eex .leex)))

    if changed != [] and match?({:ok, true}, Tools.exists("mix.exs")),
      do: Visor.Feedback.unverified(state.id, Enum.sort(changed)),
      else: []
  end

  defp paths_text(paths) do
    {shown, rest} = Enum.split(paths, 4)
    more = if rest == [], do: "", else: " and #{length(rest)} more"
    Enum.join(shown, ", ") <> more
  end

  defp finish(state, reason) do
    info = %{reason: reason, steps: state.steps}

    info =
      case reason in [:answered, :step_limit] and unchecked(state) do
        [_ | _] = unchecked -> Map.put(info, :unchecked, unchecked)
        _checked -> info
      end

    broadcast(state, {:prompt_end, info})
    state = set_status(state, :idle)

    # The model's own effort and thinking last no longer than its prompt.
    state =
      if Map.get(state, :think) do
        state = Map.put(state, :think, nil)
        broadcast(state, {:settings, public_settings(state)})
        state
      else
        state
      end

    # After Stop or a failed call, jobs that end wait for the user's next
    # prompt rather than starting one, and monitored jobs stop, as
    # pi-fabric's do: what they would tell is for an agent that goes on.
    state =
      if Wakes.holds?(reason) do
        Jobs.stop_monitored(state.id)
        # The pictures the model was to get go with what was sent.
        state |> Wakes.hold() |> Map.put(:pending_images, [])
      else
        state
      end

    case {Map.get(state, :queued, []), Wakes.holds?(reason)} do
      {[], _held} ->
        schedule_wake(state)

      {texts, true} ->
        why =
          case reason do
            :interrupted -> "was stopped"
            :budget -> "reached its spending limit"
            _failed -> "failed"
          end

        note(state, :info, "Not sent, since the prompt #{why}: " <> Enum.join(texts, "\n\n"))
        save(Map.put(state, :queued, []))

      {texts, false} ->
        start_prompt(Map.put(state, :queued, []), Enum.join(texts, "\n\n"))
    end
  end

  defp set_status(state, status) do
    broadcast(state, {:status, status})
    %{state | status: status}
  end

  defp note(state, level, text), do: broadcast(state, {:note, level, text})

  defp broadcast(%__MODULE__{id: id}, event), do: broadcast(id, event)

  defp broadcast(id, event), do: Event.broadcast(id, event)

  # What the request looks like on the wire, shortened for display. A map:
  # the console turns it into JSON, so nothing here can fail to encode.
  defp request_preview(request, info) do
    %{
      "provider" => info.provider,
      "model" => info.model,
      "thinking" => if(request.thinking, do: "enabled", else: "disabled"),
      "reasoning_effort" => if(request.thinking, do: request.effort),
      "tools" => Enum.map(request.tools, & &1.function.name),
      "message_count" => length(request.messages) + 1,
      "last_messages" => request.messages |> Enum.take(-3) |> Enum.map(&shorten/1)
    }
  end

  defp shorten(message) when is_map(message),
    do: Map.new(message, fn {k, v} -> {k, shorten(v)} end)

  defp shorten(list) when is_list(list), do: Enum.map(list, &shorten/1)

  defp shorten(text) when is_binary(text) and byte_size(text) > 240,
    do: String.slice(text, 0, 240) <> "… (#{String.length(text)} chars)"

  defp shorten(other), do: other

  defp now, do: System.monotonic_time(:millisecond)
end
