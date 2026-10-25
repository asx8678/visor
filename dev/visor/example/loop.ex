defmodule Visor.Example.Loop do
  @moduledoc """
  `mix visor.example`'s `loop` phase: the agent itself, run with the
  scripted model (`Visor.Example.ScriptedModel`), so its loop is checked
  without a network: the tool loop, steering, Stop, the spending limit, a
  sub-agent's spending and a slow parent, wakes and their limit, the
  repeat guard, compaction and `V.recall`, a request too long for the
  window, and malformed tool arguments. `mix precommit` runs it.

  Each check starts the session's conversation afresh and scripts the
  model's replies; the model refuses a request whose messages are out of
  order, as DeepSeek would.
  """

  import Visor.Example.Run

  alias Visor.Example.ScriptedModel, as: M
  alias Visor.Limits

  # A script whose value is 30 KB of text, cut to 24 KB for the model.
  @big ~S|String.duplicate("line\n", 6_000)|

  @doc "The checks, as `{name, what, fun}` (see `Visor.Example.Run`)."
  @spec checks() :: [Visor.Example.Run.check()]
  def checks do
    [
      {"runs the tool loop to an answer",
       "A script, its result, then the answer: two model calls, the second after the result.",
       &tool_loop/1},
      {"steers a running prompt",
       "A message sent while a script runs reaches the model after the script's result, in " <>
         "the same prompt.", &steering/1},
      {"stops a model call, and answers the next prompt",
       "Stop during a model call that never answers ends the prompt (:interrupted); the next " <>
         "prompt's request is in order.", &stop_call/1},
      {"stops a running script, and answers the next prompt",
       "Stop while a script runs answers its call, so the next request is in order.",
       &stop_script/1},
      {"stops a prompt at its spending limit",
       "A call that passes the prompt's limit is the last: the prompt ends :budget before " <>
         "another.", &budget/1},
      {"counts a sub-agent's spending in its parent's, a slow parent too",
       "A sub-agent's calls' costs reach its parent's prompt; with the parent suspended, the " <>
         "sub-agent holds to its last answer and says so; the job's end wakes the parent.",
       &sub_agent/1},
      {"wakes when a job ends, at most job_wakeups times",
       "Each wake starts another job; after Visor.Limits.job_wakeups/0 wakes the last job's " <>
         "end waits for the user's next prompt, which carries it.", &wakes/1},
      {"warns of a repeated script, then refuses it",
       "Six identical scripts in one batch: a warning from the 3rd, the 6th not run.",
       &repeats/1},
      {"compacts, and recalls what it summarized",
       "Compaction on request summarizes the start; V.recall still reads a summarized result.",
       &compaction/1},
      {"compacts on its own past its threshold",
       "With a threshold of 30,000 tokens, five 24 KB results set off a compaction.",
       &threshold/1},
      {"compacts and calls again when the request is too long",
       "A context overflow compacts the conversation and makes the call again, once: a " <>
         "second overflow fails the prompt.", &overflow/1},
      {"leaves out answered pictures when the request is too large",
       "An overflow in a conversation too short to compact still makes the call again " <>
         "without the picture the model had answered (a 413 from a picture's size).",
       &overflow_pictures/1},
      {"answers malformed tool arguments and goes on",
       "Code under another key runs; JSON that doesn't parse fails its call; the model gets " <>
         "both results and answers.", &malformed/1}
    ]
  end

  defp tool_loop(ctx) do
    fresh(ctx, [M.script(~S|V.ls(".")|), M.answer("It has mix.exs.")])
    step = ask(ctx, "List the files.")
    last = last_request()

    all([
      ended_as(step, [:answered]),
      event(step, "a script listing mix.exs", fn
        {:tool_end, %{status: :ok, result: result}} -> result =~ "mix.exs"
        _other -> false
      end),
      pass_if(
        roles(last) == ["user", "assistant", "tool"],
        "the last request: #{inspect(roles(last))}"
      ),
      scripted(ctx)
    ])
  end

  defp steering(ctx) do
    fresh(ctx, [M.script(~S|V.sh("sleep 1")|), M.answer("Done, and steered.")])
    step = ask(ctx, "Run a slow command.", steer: "Also: STEER ME")
    tail = Enum.take(last_request().messages, -3)

    all([
      ended_as(step, [:answered]),
      event(step, "a steer event", &match?({:steer, "Also: STEER ME"}, &1)),
      pass_if(
        Enum.map(tail, & &1["role"]) == ["assistant", "tool", "user"] and
          Visor.Content.text(List.last(tail)["content"]) =~ "STEER ME",
        "the steering message isn't after the script's result: " <>
          inspect(Enum.map(tail, &{&1["role"], String.slice(text(&1), 0, 60)}))
      ),
      scripted(ctx)
    ])
  end

  defp stop_call(ctx) do
    fresh(ctx, [M.hang(), M.answer("Back.")])
    stopped = start_and_stop(ctx, "Think forever.", &match?({:turn_start, _}, &1))
    step = ask(ctx, "Are you there?")

    all([
      pass_if(stopped == :interrupted, "the stopped prompt ended #{inspect(stopped)}"),
      ended_as(step, [:answered]),
      scripted(ctx)
    ])
  end

  defp stop_script(ctx) do
    fresh(ctx, [M.script(~S|V.sh("sleep 30")|), M.answer("Back.")])
    stopped = start_and_stop(ctx, "Run something long.", &match?({:tool_start, _}, &1))
    step = ask(ctx, "Are you there?")
    last = last_request()

    all([
      pass_if(stopped == :interrupted, "the stopped prompt ended #{inspect(stopped)}"),
      ended_as(step, [:answered]),
      pass_if(
        roles(last) == ["user", "assistant", "tool", "user"],
        "the next request: #{inspect(roles(last))}"
      ),
      scripted(ctx)
    ])
  end

  defp budget(ctx) do
    limits = Visor.Agent.settings(ctx.session).limits
    {:ok, _settings} = Visor.Agent.configure(ctx.session, budget: {:prompt, 0.05})

    try do
      fresh(ctx, [M.script("1 + 1", cost: 0.06), M.answer("Never asked for.")])
      step = ask(ctx, "Spend.")

      all([
        ended_as(step, [:budget]),
        pass_if(length(M.requests()) == 1, "#{length(M.requests())} model calls, not 1"),
        event(step, "a note of the limit", fn
          {:note, :error, text} -> text =~ "limit"
          _other -> false
        end),
        pass_if(M.misses() == [], "misses: #{inspect(M.misses())}")
      ])
    after
      {:ok, _settings} = Visor.Agent.configure(ctx.session, budget: {:prompt, limits.prompt})
    end
  end

  # The parent is this phase's agent; its prompt starts a sub-agent and
  # answers. The sub-agent's first call suspends the parent, so its second
  # finds the parent slow; its second call puts the parent back.
  defp sub_agent(ctx) do
    parent = agent_pid(ctx.session)

    fresh(ctx, [
      M.script(~S|V.agent("CHILD: say two")|, for: "PARENT"),
      M.answer("I asked a helper.", for: "PARENT"),
      M.dynamic(
        fn _request ->
          :ok = :sys.suspend(parent)
          M.script("1 + 1", cost: 0.10)
        end,
        for: "CHILD"
      ),
      M.dynamic(
        fn _request ->
          :ok = :sys.resume(parent)
          M.answer("two", cost: 0.05)
        end,
        for: "CHILD"
      ),
      M.answer("The helper said two.", for: "PARENT")
    ])

    step =
      try do
        ask(ctx, "PARENT: ask a helper.", settle: 2_500)
      after
        :sys.resume(parent)
      end

    spent = Visor.Agent.settings(ctx.session).spent.prompt
    child = Enum.find_value(step.events, &child_of/1)
    lines = if child, do: recorded(ctx, child), else: []

    slow_note =
      Enum.any?(lines, fn line ->
        line["event"] == "note" and inspect(line["data"]) =~ "didn't say in time"
      end)

    record(
      ctx,
      :runtime,
      "the parent's prompt spending, and the sub-agent #{child}'s events",
      :ok,
      "spent #{spent}\n" <> Enum.map_join(lines, "\n", &"#{&1["event"]} #{inspect(&1["data"])}")
    )

    all([
      pass_if(child != nil, "no sub-agent started"),
      pass_if(abs(spent - 0.15) < 1.0e-9, "the parent's prompt spent #{spent}, not 0.15"),
      pass_if(slow_note, "the sub-agent said nothing of its slow parent"),
      event(step, "a wake for the job's end", &match?({:wake, _text}, &1)),
      scripted(ctx)
    ])
  end

  defp wakes(ctx) do
    job = ~S|V.sh("sleep 0.2; echo ended", background: true)|
    times = Limits.job_wakeups()

    fresh(
      ctx,
      [M.script(job), M.answer("Started.")] ++
        Enum.flat_map(1..times, fn _n -> [M.script(job), M.answer("Started another.")] end)
    )

    step = ask(ctx, "Start a job.", settle: 1_500)
    woke = Enum.count(step.events, &match?({:wake, _text}, &1))
    misses = M.misses()
    jobs = for {:job_start, %{id: id}} <- step.events, uniq: true, do: id

    M.play([M.answer("Noted.")])
    next = ask(ctx, "What happened?")
    told = text(List.last(last_request().messages))

    all([
      pass_if(woke == times, "it woke #{woke} times, not #{times}"),
      pass_if(misses == [], "misses: #{inspect(misses)}"),
      ended_as(next, [:answered]),
      pass_if(
        jobs != [] and told =~ "background job #{List.last(jobs)}",
        "the next prompt didn't carry job #{List.last(jobs)}'s end: #{String.slice(told, 0, 300)}"
      ),
      scripted(ctx)
    ])
  end

  defp repeats(ctx) do
    fresh(ctx, [
      M.scripts(List.duplicate(~S|V.exists?("mix.exs")|, 6)),
      M.answer("Enough.")
    ])

    step = ask(ctx, "Check six times.")
    results = for {:tool_end, %{result: result}} <- step.events, do: result

    all([
      ended_as(step, [:answered]),
      pass_if(length(results) == 6, "#{length(results)} results, not 6"),
      pass_if(
        not (Enum.at(results, 1, "") =~ "this exact script") and
          Enum.at(results, 2, "") =~ "this exact script has run 3 times in a row",
        "the warning isn't on the 3rd: #{inspect(Enum.map(results, &String.slice(&1, -120, 120)))}"
      ),
      pass_if(Enum.at(results, 5, "") =~ "Not run", "the 6th ran"),
      event(step, "a blocked repeat", &match?({:repeat, %{count: 6, blocked: true}}, &1)),
      scripted(ctx)
    ])
  end

  defp compaction(ctx) do
    fresh(ctx, [
      M.script(@big, id: "big1"),
      M.answer("One."),
      M.script(@big, id: "big2"),
      M.answer("Two."),
      M.script(~S|V.recall("big1")|),
      M.answer("Recalled.")
    ])

    first = ask(ctx, "First.")
    second = ask(ctx, "Second.")
    before = Visor.Agent.settings(ctx.session).messages
    compacted = Visor.Agent.compact(ctx.session)
    after_compaction = Visor.Agent.settings(ctx.session).messages
    record(ctx, :runtime, "Visor.Agent.compact(session)", :ok, inspect(compacted, pretty: true))
    step = ask(ctx, "Recall the first.")

    recalled =
      Enum.find_value(step.events, "", fn
        {:tool_end, %{result: result}} -> result
        _other -> nil
      end)

    all([
      ended_as(first, [:answered]),
      ended_as(second, [:answered]),
      pass_if(
        match?({:ok, %{reason: :manual, summarized: n}} when n > 0, compacted),
        "the compaction: #{inspect(compacted)}"
      ),
      pass_if(after_compaction < before, "#{before} messages before, #{after_compaction} after"),
      ended_as(step, [:answered]),
      pass_if(recalled =~ "line\nline", "V.recall gave: #{String.slice(recalled, 0, 200)}"),
      pass_if(
        text(hd(last_request().messages)) =~ "[Visor compaction]",
        "the request after it doesn't start with the summary"
      ),
      scripted(ctx)
    ])
  end

  defp threshold(ctx) do
    fresh(
      ctx,
      Enum.flat_map(1..5, fn n -> [M.script(@big), M.answer("Result #{n}.")] end),
      compact_tokens: 30_000
    )

    steps = for n <- 1..5, do: ask(ctx, "Big result #{n}.")
    events = Enum.flat_map(steps, & &1.events)

    all([
      all(Enum.map(steps, &ended_as(&1, [:answered]))),
      pass_if(
        Enum.any?(
          events,
          &match?({:compaction, %{reason: :threshold, kept: kept}} when kept > 0, &1)
        ),
        "no compaction past the threshold"
      ),
      scripted(ctx)
    ])
  end

  @window "This model's maximum context length is 131072 tokens."

  # Five big results, so the conversation is long enough to compact.
  defp overflow(ctx) do
    fresh(
      ctx,
      Enum.flat_map(1..5, fn n -> [M.script(@big), M.answer("Result #{n}.")] end) ++
        [M.overflow(@window), M.answer("It fits now."), M.overflow(@window), M.overflow(@window)]
    )

    for n <- 1..5, do: ask(ctx, "Big result #{n}.")
    step = ask(ctx, "Sum them up.")
    # Overflowing again, it fails: at once when what was just compacted
    # can't be made smaller, or after one more call when it can.
    again = ask(ctx, "Once more.")

    all([
      ended_as(step, [:answered]),
      event(
        step,
        "a compaction for the overflow",
        &match?({:compaction, %{reason: :overflow}}, &1)
      ),
      event(step, "a note that the call was made again", fn
        {:note, :info, text} -> text =~ "compacted and the call made again"
        _other -> false
      end),
      ended_as(again, [:model_error]),
      pass_if(M.misses() == [], "misses: #{inspect(M.misses())}")
    ])
  end

  defp overflow_pictures(ctx) do
    fresh(ctx, [M.script("1 + 1"), M.overflow("Request Entity Too Large"), M.answer("Seen.")])
    part = Visor.Content.image("image/png", red_png())
    step = ask(ctx, "Look at this.", pictures: [{"red.png", part}])
    pictures = Enum.map(M.requests(), &images/1)

    all([
      ended_as(step, [:answered]),
      event(step, "a note that the pictures were left out", fn
        {:note, :info, text} -> text =~ "pictures it had answered were left out"
        _other -> false
      end),
      # The picture went with the call that ran the script and the one the
      # provider refused; the call made again leaves it out.
      pass_if(
        pictures == [1, 1, 0],
        "messages with pictures in each request: #{inspect(pictures)}"
      ),
      scripted(ctx)
    ])
  end

  defp malformed(ctx) do
    fresh(ctx, [
      M.call([~S|{"script": "1 + 1"}|, ~S|{"code": "1 + |]),
      M.answer("Went on.")
    ])

    step = ask(ctx, "Run two scripts.")
    ends = for {:tool_end, %{status: status, result: result}} <- step.events, do: {status, result}

    all([
      ended_as(step, [:answered]),
      pass_if(
        match?([{:ok, "ok" <> _}, {:error, _}], ends),
        "the calls ended: #{inspect(Enum.map(ends, fn {s, r} -> {s, String.slice(r, 0, 80)} end))}"
      ),
      event(step, "a repair event", &match?({:repair, %{reason: :arguments}}, &1)),
      pass_if(
        roles(last_request()) == ["user", "assistant", "tool", "tool"],
        "the last request: #{inspect(roles(last_request()))}"
      ),
      scripted(ctx)
    ])
  end

  ## Helpers

  # The conversation afresh, the agent idle, and `replies` scripted.
  defp fresh(ctx, replies, opts \\ []) do
    case Visor.Agent.reset(ctx.session) do
      :ok ->
        :ok

      {:error, :busy} ->
        _ = Visor.Agent.interrupt(ctx.session)
        wait_for(&(&1 == {:status, :idle}), 10_000)
        :ok = Visor.Agent.reset(ctx.session)
    end

    M.play(replies, opts)
  end

  defp ask(ctx, text, opts \\ []), do: prompt(ctx, text, Keyword.put_new(opts, :settle, 300))

  # Starts a prompt, stops it once `started?` matches one of its events,
  # and returns how it ended.
  defp start_and_stop(ctx, text, started?) do
    :ok = Visor.Agent.prompt(ctx.session, text)

    with {:ok, _event, _events} <- wait_for(started?, 10_000),
         :ok <- Visor.Agent.interrupt(ctx.session),
         {:ok, {:prompt_end, %{reason: reason}}, _events} <-
           wait_for(&match?({:prompt_end, _}, &1), 10_000) do
      reason
    else
      other -> {:not_stopped, other}
    end
  end

  defp ended_as(step, reasons) do
    ended = for {:prompt_end, %{reason: reason}} <- step.events, do: reason
    pass_if(ended == reasons, "the prompt ended #{inspect(ended)}, not #{inspect(reasons)}")
  end

  # Every reply taken, no request without one, and none that Repair had
  # to put in order (Visor.Agent.Repair is for an agent that crashed; the
  # loop itself keeps its messages in order).
  defp scripted(ctx) do
    repaired =
      for step <- Agent.get(ctx.sink, & &1.steps),
          {:repair, %{reason: reason}} <- step.events,
          reason in [:request, :restart],
          do: reason

    all([
      pass_if(
        M.misses() == [],
        "the model got requests it had no reply for: #{inspect(M.misses())}"
      ),
      pass_if(M.left() == [], "#{length(M.left())} replies were never asked for"),
      pass_if(repaired == [], "Repair had to put the messages in order: #{inspect(repaired)}")
    ])
  end

  defp last_request, do: List.last(M.requests()) || %{messages: []}
  defp roles(request), do: Enum.map(request.messages, & &1["role"])
  defp text(nil), do: ""
  defp text(message), do: Visor.Content.text(message["content"])

  defp images(request),
    do: Enum.count(request.messages, &(Visor.Content.images(&1["content"]) > 0))

  defp child_of({:job_start, %{kind: :agent, child: child}}) when is_binary(child), do: child
  defp child_of(_event), do: nil
end
