defmodule Visor.Reviewer do
  @moduledoc """
  A session's quiet reviewer, after pi-fabric's advisor and supervisor:
  an outside observer of the agent's work that speaks only when it has
  something material to say. Idle until the console turns it on:

    * `/advisor [focus]`: reviews when a prompt ends and when a tool call
      fails, and its message reaches the model at the next natural point
      (after the running tool calls, or with the next prompt). It never
      starts a prompt.
    * `/supervise goal`: the same, toward a goal; its message may also
      start a prompt when the agent is idle (a wake, within
      `Visor.Limits.job_wakeups/0`), and once it sees the goal met it says
      so and turns itself off.

  Each review is one model call of its own, without tools, at low effort
  and without thinking, asked for JSON:
  `{"action": "silent" | "message" | "stop", "message": "..."}`. It sees
  a bounded digest of the conversation, never the whole. At most one
  review when a prompt ends and `Visor.Limits.reviews_per_prompt/0` in
  all per prompt from the user.
  """
  use GenServer

  alias Visor.{Harness, Limits, Model}
  alias Visor.Agent.Event
  alias Visor.Harness.Session

  @advisor """
  [Visor review] You are a peer advisor for a coding agent. Review the conversation digest \
  below as an outside observer, not a second executor: correctness, missed user constraints, \
  risky assumptions, edge cases and cheaper paths to what the user asked. Prefer silence. \
  Reply with JSON only: {"action":"silent"} when the work is on track, or \
  {"action":"message","message":"..."} for one concrete, material observation that could \
  prevent wasted work or a defect while there is still time. Cite the evidence tersely, as \
  advice, not an order. Don't repeat advice already in the digest.\
  """

  @supervisor """
  [Visor review] You supervise a coding agent toward a goal. Review the conversation digest \
  below as an outside observer, not an implementer. Reply with JSON only: \
  {"action":"silent"} while the work is advancing, {"action":"message","message":"..."} when \
  material work is missing, the work drifts, an error left it stuck, or one concrete next \
  action is needed (at most three sentences), or {"action":"stop","message":"..."} once the \
  goal and its validation are evident.\
  """

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, id, name: Harness.via({id, :reviewer}))
  end

  @doc "Turns session `id`'s reviewer on as `:advisor` or `:supervisor`, with its focus or goal."
  def start(id, mode, text) when mode in [:advisor, :supervisor],
    do: GenServer.call(Harness.via({id, :reviewer}), {:start, mode, text})

  @doc "Turns session `id`'s reviewer off."
  def stop(id), do: GenServer.call(Harness.via({id, :reviewer}), :stop)

  @doc "What session `id`'s reviewer is doing: nil, or `%{mode, text}`."
  def status(id), do: GenServer.call(Harness.via({id, :reviewer}), :status)

  ## Server

  @impl true
  def init(id) do
    Process.set_label("reviewer #{id}")
    :ok = Event.subscribe(id)
    {:ok, %{id: id, mode: nil, text: nil, task: nil, reviews: 0, tool_reviews: 0}}
  end

  @impl true
  def handle_call({:start, mode, text}, _from, state) do
    state = %{state | mode: mode, text: text, reviews: 0, tool_reviews: 0}
    {:reply, :ok, state}
  end

  def handle_call(:stop, _from, state), do: {:reply, :ok, %{state | mode: nil, text: nil}}

  def handle_call(:status, _from, %{mode: nil} = state), do: {:reply, nil, state}

  def handle_call(:status, _from, state),
    do: {:reply, %{mode: state.mode, text: state.text}, state}

  @impl true
  # The user's own prompt: a fresh allowance of reviews.
  def handle_info({:agent, {:user, _text}}, state),
    do: {:noreply, %{state | reviews: 0, tool_reviews: 0}}

  def handle_info({:agent, {:prompt_end, %{reason: reason}}}, %{mode: mode} = state)
      when mode != nil and reason != :interrupted do
    {:noreply, review(state, "the prompt ended (#{reason})")}
  end

  def handle_info({:agent, {:tool_end, %{status: :error, result: result}}}, %{mode: mode} = state)
      when mode != nil do
    if state.tool_reviews < 2 do
      state = %{state | tool_reviews: state.tool_reviews + 1}
      {:noreply, review(state, "a tool call failed: " <> String.slice(result, 0, 400))}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, answered(%{state | task: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, %{state | task: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  # One review at a time, and a bounded number per prompt from the user.
  defp review(%{task: %Task{}} = state, _why), do: state

  defp review(state, why) do
    if state.reviews >= Limits.reviews_per_prompt() do
      state
    else
      request = %{
        system: system(state),
        messages: [%{"role" => "user", "content" => digest(state.id, why)}],
        tools: [],
        tool_choice: "none",
        effort: "low",
        thinking: false
      }

      provider = Model.current()
      tasks = Harness.via({state.id, :tasks})
      task = Harness.async(tasks, "review", fn -> provider.stream(request, fn _ -> :ok end) end)
      %{state | task: task, reviews: state.reviews + 1}
    end
  end

  defp system(%{mode: :advisor, text: focus}) when focus not in [nil, ""],
    do: @advisor <> " Focus on: " <> focus

  defp system(%{mode: :advisor}), do: @advisor
  defp system(%{mode: :supervisor, text: goal}), do: @supervisor <> "\n\nThe goal: " <> goal

  defp answered(state, {:ok, %{message: message, usage: usage}}) do
    {action, text} = parse(message["content"] || "")

    Event.broadcast(
      state.id,
      {:review, %{mode: state.mode, action: action, message: text, usage: usage}}
    )

    case {action, state.mode} do
      {:message, mode} when text != "" ->
        who = if mode == :advisor, do: "advisor", else: "supervisor"
        Visor.Agent.review(state.id, "[Visor #{who}: #{text}]", mode == :supervisor)
        state

      {:stop, :supervisor} ->
        %{state | mode: nil, text: nil}

      _silent ->
        state
    end
  end

  defp answered(state, _error), do: state

  # The model's JSON, wherever it is in the reply; anything else is
  # silence.
  defp parse(content) do
    with [json] <- Regex.run(~r/\{.*\}/s, content),
         {:ok, %{"action" => action} = reply} <- Jason.decode(json),
         action when action in ~w(silent message stop) <- action do
      {String.to_existing_atom(action), String.trim(to_string(reply["message"] || ""))}
    else
      _ -> {:silent, ""}
    end
  end

  # The conversation's last messages, each cut, within a few KB.
  defp digest(id, why) do
    messages =
      with store when store != nil <- Session.store(id),
           [{:conversation, %{messages: messages}}] <- :ets.lookup(store, :conversation) do
        messages
      else
        _ -> []
      end

    lines =
      messages
      |> Enum.take(-Limits.review_messages())
      |> Enum.map(fn message ->
        text =
          case message do
            %{"tool_calls" => [_ | _] = calls} ->
              "calls: " <> Enum.map_join(calls, "; ", &get_in(&1, ["function", "arguments"]))

            %{"content" => content} when is_binary(content) ->
              content

            _ ->
              ""
          end

        "#{message["role"]}: " <> String.slice(text, 0, 600)
      end)

    "Why you are asked now: #{why}.\n\nThe conversation's last messages:\n\n" <>
      Enum.join(lines, "\n\n")
  end
end
