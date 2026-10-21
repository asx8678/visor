defmodule Visor.Agent do
  @moduledoc """
  The agent loop for one console session.

  Each model call and each tool call runs as its own task under the
  session's task supervisor. That keeps the loop responsive (it can be
  interrupted mid-stream) and puts every step in the process view.

  Events are broadcast on `topic(id)` as `{:agent, event}`.
  """
  use GenServer

  alias Visor.{Harness, Model, Tools}

  # Model calls allowed for one prompt before the loop gives up.
  @max_steps 24
  @efforts ~w(low high max)

  @system """
  You are Visor, a coding agent running inside an Elixir/OTP harness. You can explore, \
  read and change the user's project and run shell commands in it with your tools. Every \
  model call and tool call you make runs in its own supervised BEAM process, which the user \
  watches in a live process view.

  Work in code mode: prefer the elixir tool, and write one script per step that does every \
  read, search, edit and command the step needs, then returns only what you need to see. \
  Use the single tools only for a quick one-off lookup.

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
    messages: [],
    status: :idle,
    turn: 0,
    steps: 0,
    effort: "high",
    thinking: true,
    tool_tasks: %{},
    tool_results: %{},
    pending_calls: [],
    # Prompt tokens the last request sent, to notice when the next one
    # misses the provider's cache.
    last_prompt_tokens: nil
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :id)))
  end

  def topic(id), do: "agent:#{id}"
  def subscribe(id), do: Phoenix.PubSub.subscribe(Visor.PubSub, topic(id))
  def efforts, do: @efforts

  @doc "Sends a user prompt. Returns `{:error, :busy}` while a prompt is running."
  def prompt(id, text), do: GenServer.call(via(id), {:prompt, text})

  @doc "Interrupts the running model call or tools."
  def interrupt(id), do: GenServer.call(via(id), :interrupt)

  @doc "Forgets the conversation."
  def reset(id), do: GenServer.call(via(id), :reset)

  @doc "Changes `:effort` or `:thinking`."
  def configure(id, settings), do: GenServer.call(via(id), {:configure, settings})

  def settings(id), do: GenServer.call(via(id), :settings)

  defp via(id), do: Harness.via({id, :agent})

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    Process.set_label("agent #{id}")
    owner_ref = Process.monitor(Keyword.fetch!(opts, :owner))
    {:ok, %__MODULE__{id: id, owner_ref: owner_ref, tasks: Keyword.fetch!(opts, :tasks)}}
  end

  @impl true
  def handle_call({:prompt, text}, _from, %{status: :idle} = state) do
    broadcast(state, {:user, text})
    state = %{push_user(state, text) | steps: 0}
    {:reply, :ok, start_turn(state)}
  end

  def handle_call({:prompt, _text}, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call(:interrupt, _from, %{model_task: %Task{} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    broadcast(state, {:turn_end, %{turn: state.turn, finish_reason: "interrupted"}})
    note(state, :info, "Stopped. The partial response was discarded.")
    {:reply, :ok, finish(%{state | model_task: nil}, :interrupted)}
  end

  def handle_call(:interrupt, _from, state) when map_size(state.tool_tasks) > 0 do
    for {_ref, {task, call, _started}} <- state.tool_tasks do
      # A shutdown rather than a kill, so linked helpers such as Dune's
      # sandbox exit quietly instead of logging a crash.
      Task.shutdown(task)

      broadcast(
        state,
        {:tool_end, Map.merge(call, %{status: :error, result: "Cancelled.", ms: nil})}
      )
    end

    results =
      Map.new(state.pending_calls, fn call ->
        {call.id, Map.get(state.tool_results, call.id, "Cancelled by the user.")}
      end)

    state = append_tool_results(%{state | tool_tasks: %{}, tool_results: results})
    note(state, :info, "Stopped. The running tools were cancelled.")
    {:reply, :ok, finish(state, :interrupted)}
  end

  def handle_call(:interrupt, _from, state), do: {:reply, {:error, :idle}, state}

  def handle_call(:reset, _from, %{status: :idle} = state) do
    broadcast(state, {:context, 0})
    {:reply, :ok, %{state | messages: [], last_prompt_tokens: nil}}
  end

  def handle_call(:reset, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call({:configure, settings}, _from, state) do
    case apply_settings(state, settings) do
      {:ok, state} ->
        broadcast(state, {:settings, public_settings(state)})
        {:reply, {:ok, public_settings(state)}, state}

      {:error, message} ->
        {:reply, {:error, message}, state}
    end
  end

  def handle_call(:settings, _from, state), do: {:reply, public_settings(state), state}

  @impl true
  def handle_info({ref, result}, %{model_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, handle_model_result(result, %{state | model_task: nil})}
  end

  def handle_info({ref, result}, state) when is_map_key(state.tool_tasks, ref) do
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
      when is_map_key(state.tool_tasks, ref) do
    {:noreply,
     finish_tool(state, ref, {:error, "The tool crashed: #{Exception.format_exit(reason)}"})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_turn(state) do
    provider = Model.current()
    info = provider.info()
    turn = state.turn + 1
    id = state.id

    request = %{
      system: @system,
      messages: state.messages,
      tools: Tools.definitions(),
      effort: state.effort,
      thinking: state.thinking
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

    broadcast(
      state,
      {:turn_start,
       %{
         turn: turn,
         step: state.steps + 1,
         max_steps: @max_steps,
         provider: info,
         effort: state.effort,
         thinking: state.thinking,
         messages: length(state.messages),
         pid: task.pid
       }}
    )

    broadcast(state, {:request, turn, request_preview(request, info)})
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

    state = %{state | last_prompt_tokens: prompt_tokens(result.usage, state.last_prompt_tokens)}

    state =
      case {result.finish_reason, result.tool_calls} do
        {"tool_calls", [_ | _] = calls} ->
          state |> append(result.message) |> run_tools(calls)

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
    broadcast(state, {:context, length(state.messages)})
    state
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
  def cache_warning(previous, %{"prompt_cache_hit_tokens" => hit, "prompt_tokens" => prompt})
      when is_integer(previous) and previous >= 4096 and is_integer(hit) and hit < previous * 0.8 do
    "The cache served #{hit} of this request's #{prompt} prompt tokens, but the previous " <>
      "request sent #{previous}. The start of the conversation changed, or the cache " <>
      "wasn't ready yet."
  end

  def cache_warning(_previous, _usage), do: nil

  defp prompt_tokens(%{"prompt_tokens" => tokens}, _previous) when is_integer(tokens), do: tokens
  defp prompt_tokens(_usage, previous), do: previous

  defp run_tools(state, calls) do
    tool_tasks =
      Map.new(calls, fn call ->
        context = %{session: state.id, call_id: call.id}

        task =
          Harness.async(state.tasks, "tool #{call.name}", fn ->
            Tools.run(call.name, call.arguments, context)
          end)

        broadcast(state, {:tool_start, Map.merge(call, %{status: :running, pid: task.pid})})
        {task.ref, {task, call, now()}}
      end)

    set_status(%{state | tool_tasks: tool_tasks, tool_results: %{}, pending_calls: calls}, :tools)
  end

  defp finish_tool(state, ref, result) do
    {{_task, call, started}, tool_tasks} = Map.pop(state.tool_tasks, ref)
    {status, output} = result

    broadcast(
      state,
      {:tool_end, Map.merge(call, %{status: status, result: output, ms: now() - started})}
    )

    state = %{
      state
      | tool_tasks: tool_tasks,
        tool_results: Map.put(state.tool_results, call.id, output)
    }

    cond do
      map_size(tool_tasks) > 0 ->
        state

      state.steps >= @max_steps ->
        state = append_tool_results(state)
        note(state, :error, "Stopped after #{@max_steps} model calls for one prompt.")
        finish(state, :step_limit)

      true ->
        state |> append_tool_results() |> start_turn()
    end
  end

  defp append_tool_results(state) do
    messages =
      for call <- state.pending_calls do
        %{"role" => "tool", "tool_call_id" => call.id, "content" => state.tool_results[call.id]}
      end

    %{state | messages: state.messages ++ messages, pending_calls: [], tool_results: %{}}
  end

  # After an interrupted model call the last message is an unanswered user
  # prompt; fold the new prompt into it instead of sending two in a row.
  defp push_user(%{messages: messages} = state, text) do
    case List.last(messages) do
      %{"role" => "user", "content" => previous} ->
        %{
          state
          | messages:
              List.replace_at(messages, -1, %{
                "role" => "user",
                "content" => previous <> "\n\n" <> text
              })
        }

      _ ->
        append(state, %{"role" => "user", "content" => text})
    end
  end

  defp append(state, message), do: %{state | messages: state.messages ++ [message]}

  defp apply_settings(state, settings) do
    Enum.reduce_while(settings, {:ok, state}, fn
      {:effort, effort}, {:ok, state} when effort in @efforts ->
        {:cont, {:ok, %{state | effort: effort}}}

      {:effort, effort}, _ ->
        {:halt, {:error, "Effort must be one of #{Enum.join(@efforts, ", ")}, not #{effort}."}}

      {:thinking, thinking}, {:ok, state} when is_boolean(thinking) ->
        {:cont, {:ok, %{state | thinking: thinking}}}
    end)
  end

  defp public_settings(state) do
    %{
      effort: state.effort,
      thinking: state.thinking,
      status: state.status,
      messages: length(state.messages),
      provider: Model.current().info()
    }
  end

  # Ends the running prompt: the reply came, or why it didn't.
  defp finish(state, reason) do
    broadcast(state, {:prompt_end, %{reason: reason, steps: state.steps}})
    set_status(state, :idle)
  end

  defp set_status(state, status) do
    broadcast(state, {:status, status})
    %{state | status: status}
  end

  defp note(state, level, text), do: broadcast(state, {:note, level, text})

  defp broadcast(%__MODULE__{id: id}, event), do: broadcast(id, event)

  defp broadcast(id, event),
    do: Phoenix.PubSub.broadcast(Visor.PubSub, topic(id), {:agent, event})

  # What the request looks like on the wire, shortened for display.
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
    |> Jason.encode!(pretty: true)
  end

  defp shorten(message) when is_map(message),
    do: Map.new(message, fn {k, v} -> {k, shorten(v)} end)

  defp shorten(list) when is_list(list), do: Enum.map(list, &shorten/1)

  defp shorten(text) when is_binary(text) and byte_size(text) > 240,
    do: String.slice(text, 0, 240) <> "… (#{String.length(text)} chars)"

  defp shorten(other), do: other

  defp now, do: System.monotonic_time(:millisecond)
end
