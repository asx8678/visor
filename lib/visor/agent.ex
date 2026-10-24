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
  alias Visor.Agent.{Event, Repair}
  alias Visor.Harness.Session

  # Model calls allowed for one prompt. The last runs without tools, so the
  # model reports where it got to instead of stopping mid-task.
  @max_steps 24
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
    # Wakes since the user's last prompt, and whether they wait for the
    # next one (after Stop or a failed model call).
    wakes: 0,
    wakes_held: false,
    jobs_wake: true,
    wake_timer: nil,
    # What the model asked every summary to keep (V.carry/1), and its
    # request to compact at the next settled step (V.compact/1).
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
    think: nil
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :id)))
  end

  defdelegate subscribe(id), to: Event

  @doc "Tells session `id`'s agent that background job `job_id` ended."
  def job_ended(id, job_id), do: GenServer.cast(via(id), {:job_ended, job_id})
  def efforts, do: @efforts

  @doc """
  Sends a user prompt. While one is running it steers that one instead and
  returns `:queued`: the text reaches the model after the running tool
  calls, or starts the next prompt if the model answers first.
  """
  def prompt(id, text), do: GenServer.call(via(id), {:prompt, text})

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
  Asks for the conversation to be compacted at the next settled step,
  before the next model call (`V.compact/1`).
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
    with store when store != nil <- Session.store(id),
         [{:conversation, %{messages: messages}}] <- :ets.lookup(store, :conversation),
         %{"content" => content} <-
           Enum.find(messages, &(&1["role"] == "tool" and &1["tool_call_id"] == call_id)) do
      {:ok, content}
    else
      _ -> {:error, "There is no tool result #{call_id} in this conversation."}
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
      system: system_prompt(Keyword.get(opts, :role)),
      depth: Keyword.get(opts, :depth, 0)
    }

    {:ok, restore(state)}
  end

  @restarted "Not run: the agent restarted before this call finished."
  @missing "No result: this call's result was missing from the conversation."

  @impl true
  def handle_call({:prompt, text}, _from, %{status: :idle} = state) do
    {:reply, :ok, start_prompt(state, text)}
  end

  def handle_call({:prompt, text}, _from, state) do
    broadcast(state, {:steer, text})
    {:reply, :queued, save(Map.put(state, :queued, Map.get(state, :queued, []) ++ [text]))}
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
    tokens = round(Map.get(state, :last_estimate, 0) * Map.get(state, :token_scale, 1.0))
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
  def handle_cast({:job_ended, job_id}, state) do
    pending = Map.get(state, :pending_jobs, [])
    pending = if job_id in pending, do: pending, else: pending ++ [job_id]
    {:noreply, schedule_wake(Map.put(state, :pending_jobs, pending))}
  end

  @impl true
  def handle_info({ref, result}, %{model_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, handle_model_result(result, %{state | model_task: nil})}
  end

  def handle_info({ref, result}, state) when is_map_key(state.tools, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_tool(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{model_task: %Task{ref: ref}} = state) do
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
        {:noreply, handle_model_result(result, %{state | model_task: nil})}

      _stopped ->
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

  def handle_info(:wake, state) do
    state = Map.put(state, :wake_timer, nil)

    if state.status == :idle and can_wake?(state) do
      case take_notices(state) do
        {state, []} -> {:noreply, state}
        {state, notices} -> {:noreply, start_wake(state, notices)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_prompt(state, text) do
    broadcast(state, {:user, text})
    {state, notices} = take_notices(state)
    text = Enum.join([text | notices], "\n\n")

    state
    |> push_user(text)
    |> Map.merge(%{steps: 0, overflowed: false, repeat: nil, wakes: 0, wakes_held: false})
    |> start_turn()
  end

  # A prompt of the agent's own, when background jobs ended while it was
  # idle: a fresh budget of model calls, without the user.
  defp start_wake(state, notices) do
    text = Enum.join(notices, "\n\n")
    broadcast(state, {:wake, text})

    state
    |> push_user(text)
    |> Map.merge(%{
      steps: 0,
      overflowed: false,
      repeat: nil,
      wakes: Map.get(state, :wakes, 0) + 1
    })
    |> start_turn()
  end

  # What the model hasn't heard of the jobs that ended. Taking them marks
  # them as heard.
  defp take_notices(state) do
    notices =
      for id <- Map.get(state, :pending_jobs, []),
          job = Jobs.get(state.id, id),
          job && job.status != :running && not job.acknowledged do
        Jobs.acknowledge(state.id, id)
        Jobs.notice(job)
      end

    {Map.put(state, :pending_jobs, []), notices}
  end

  defp can_wake?(state) do
    Map.get(state, :jobs_wake, true) and not Map.get(state, :wakes_held, false) and
      Map.get(state, :wakes, 0) < Limits.job_wakeups()
  end

  # Jobs that end close together wake the agent once.
  defp schedule_wake(state) do
    if state.status == :idle and Map.get(state, :pending_jobs, []) != [] and can_wake?(state) and
         Map.get(state, :wake_timer) == nil do
      Map.put(state, :wake_timer, Process.send_after(self(), :wake, Limits.job_wake_batch_ms()))
    else
      state
    end
  end

  defp start_turn(state) do
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
          state |> append(result.message) |> finish(:answered)

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

  # The provider rejected the request as longer than its window: the
  # window is smaller than that request, so compact under it and try once
  # more.
  defp handle_model_result({:error, :context_overflow, message}, state) do
    broadcast(state, {:turn_end, %{turn: state.turn, finish_reason: "error"}})
    sent = round(Map.get(state, :last_estimate, 0) * Map.get(state, :token_scale, 1.0))
    window = max(floor(sent * 0.9), 1)

    with false <- Map.get(state, :overflowed, false),
         {:ok, state, _info} <-
           compact_messages(Map.put(state, :overflowed, true), :overflow, window) do
      note(
        state,
        :info,
        "The request was longer than the model's window, so the conversation was compacted " <>
          "and the call made again."
      )

      start_turn(state)
    else
      _ ->
        note(state, :error, message)
        finish(state, :model_error)
    end
  end

  defp handle_model_result({:error, message}, state) do
    broadcast(state, {:turn_end, %{turn: state.turn, finish_reason: "error"}})
    note(state, :error, message)
    finish(state, :model_error)
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

  # A compaction the model asked for is made here, the next settled step;
  # otherwise only past the threshold.
  defp maybe_compact(state) do
    {reason, state} =
      case Map.get(state, :compact_request) do
        nil -> {:threshold, state}
        request -> {:requested, Map.merge(state, %{compact_request: nil, requested: request})}
      end

    case compact_messages(state, reason) do
      {:ok, state, _info} -> Map.delete(state, :requested)
      :keep -> Map.delete(state, :requested)
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
  # (`:manual`, `:overflow`). The cache misses once after a compaction, so
  # the next request is not compared with the last.
  defp compact_messages(state, reason, window \\ nil) do
    provider = Model.current().info()
    current = Map.get(state, :compaction)

    result =
      Compaction.compact(state.messages,
        compaction: current,
        facts: Map.get(state, :facts, %{}),
        fixed: fixed_estimate(),
        scale: Map.get(state, :token_scale, 1.0),
        threshold: threshold(provider),
        window: window || provider[:context_window],
        force: reason != :threshold,
        carry: Map.get(state, :carry, [])
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
        {state, count} = repeat(state, call)

        if count >= Limits.repeat_block() do
          # Not run: it still starts and ends, like a cancelled call.
          broadcast(state, {:tool_start, Map.merge(call, %{status: :running, pid: nil})})
          state = put_in(state.tools[ref].started, now())
          finish_tool(state, ref, {:error, repeat_blocked(count), []})
        else
          run_tool(state, ref, Map.put(tool, :repeat, count))
        end
    end
  end

  defp run_tool(state, ref, %{call: call} = tool) do
    context = %{session: state.id, call_id: call.id}

    task =
      Harness.async(state.tasks, "tool #{call.name}", fn ->
        Tools.execute(call.name, call.arguments, context)
      end)

    deadline = Limits.tool_deadline_ms(Visor.Code.timeout_ms(asked_timeout(call)))
    Process.send_after(self(), {:deadline, task.ref}, deadline)
    broadcast(state, {:tool_start, Map.merge(call, %{status: :running, pid: task.pid})})
    tool = Map.merge(tool, %{task: task, started: now(), deadline: deadline})
    %{state | tools: state.tools |> Map.delete(ref) |> Map.put(task.ref, tool)}
  end

  # Counts a script run again unchanged, back to back: models in a loop
  # rerun the same script and spend the prompt's model calls on it.
  defp repeat(state, call) do
    hash = :erlang.phash2({call.name, script_text(call.arguments)})

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
  defp asked_timeout(call) do
    case Jason.decode(call.arguments) do
      {:ok, %{"timeout" => seconds}} -> seconds
      _other -> nil
    end
  end

  defp script_text(arguments) do
    case Jason.decode(arguments) do
      {:ok, %{"code" => code}} when is_binary(code) -> String.trim(code)
      _other -> arguments
    end
  end

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
  # Background jobs that ended come after them.
  defp steer(state) do
    {state, notices} = take_notices(state)

    case Map.get(state, :queued, []) ++ notices do
      [] ->
        state

      texts ->
        message = %{"role" => "user", "content" => Enum.join(texts, "\n\n")}
        state |> Map.put(:queued, []) |> append(message)
    end
  end

  # What a crashed task's exit says, without its stack frames: they are
  # the harness's, not the script's.
  defp exit_text({exception, stack}) when is_exception(exception) and is_list(stack),
    do: Exception.format_banner(:error, exception, stack)

  defp exit_text(reason), do: Exception.format_exit(reason)

  defp last_step?(state, step), do: step >= max_steps(state)

  defp max_steps(state), do: Map.get(state, :max_steps, @max_steps)

  # A sub-agent's system prompt says what it is for (V.agent/2).
  defp system_prompt(nil), do: @system

  defp system_prompt(role) do
    @system <>
      "\nYou are a sub-agent: another Visor agent gave you its task as the user's message, " <>
      "and only your final answer goes back to it. Do the task, then answer briefly with " <>
      "what it needs: results, file paths, what failed. Your role: " <> role
  end

  # What goes after a batch's last result: the calls left, and the jobs
  # still running, so the model knows it will hear of them.
  defp footer(state) do
    case Enum.reject([steps_left(state), running_jobs(state)], &is_nil/1) do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  defp running_jobs(state) do
    case Jobs.running(state.id) do
      [] ->
        nil

      jobs ->
        shown = jobs |> Enum.take(8) |> Enum.map_join(", ", &"#{&1.id} (#{Jobs.label(&1)})")
        more = if length(jobs) > 8, do: " and #{length(jobs) - 8} more", else: ""

        "[Visor: running in the background: #{shown}#{more}. Don't poll them: you'll hear " <>
          "when each ends, after your next tool calls or as a message of its own.]"
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
        message = %{"role" => "user", "content" => previous <> "\n\n" <> text}
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
  # results that had come in, and the rest as not run.
  defp restore(%{store: nil} = state), do: state

  defp restore(state) do
    case :ets.lookup(state.store, :conversation) do
      [{:conversation, conversation}] ->
        state
        |> struct(Map.delete(conversation, :batch))
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
      pending -> Map.merge(state, %{pending_jobs: pending, wakes_held: true})
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
    end)
  end

  defp public_settings(state) do
    %{
      effort: state.effort,
      thinking: state.thinking,
      jobs_wake: Map.get(state, :jobs_wake, true),
      think: Map.get(state, :think),
      status: state.status,
      messages: length(surface(state)),
      provider: Model.current().info()
    }
  end

  # Ends the running prompt: the reply came, or why it didn't. What the user
  # sent while it ran and the model never saw is the next prompt, unless
  # the user stopped this one or the model call failed, which the next
  # would likely do too.
  defp finish(state, reason) do
    broadcast(state, {:prompt_end, %{reason: reason, steps: state.steps}})
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
    # prompt rather than starting one.
    state =
      if reason in [:interrupted, :model_error, :model_crashed],
        do: Map.put(state, :wakes_held, true),
        else: state

    case {Map.get(state, :queued, []), reason} do
      {[], _reason} ->
        schedule_wake(state)

      {texts, reason} when reason in [:interrupted, :model_error, :model_crashed] ->
        why = if reason == :interrupted, do: "was stopped", else: "failed"
        note(state, :info, "Not sent, since the prompt #{why}: " <> Enum.join(texts, "\n\n"))
        save(Map.put(state, :queued, []))

      {texts, _reason} ->
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
