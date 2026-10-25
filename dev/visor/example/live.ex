defmodule Visor.Example.Live do
  @moduledoc """
  `mix visor.example`'s checks with the model: prompts to the agent, in
  order, on one copy of the example, each held to the run's budget. What
  the model says varies from run to run, so they check what it did
  (its calls, the files, the events) more than its words.
  """

  import Visor.Example.Run

  @doc "The checks, as `{name, what, fun}` (see `Visor.Example.Run`)."
  @spec checks() :: [Visor.Example.Run.check()]
  def checks do
    [
      {"fixes the bug, and checks it",
       "The model finds why two tests fail, fixes lib/ (not the tests) and runs V.check; a " <>
         "message sent while it works steers it. mix test is run again here afterwards.",
       &fixes_the_bug/1},
      {"wakes for a background job's end",
       "A job started in the background tells the idle agent when it ends, and the agent " <>
         "wakes on its own to report it.", &wakes/1},
      {"sees a picture the user sends",
       "A picture sent with the prompt reaches the model with it.", &sees_a_picture/1},
      {"shows the user's picture again in a later prompt",
       "The next prompt leaves the earlier picture out of the requests; " <>
         ~S|V.image("picture:red.png") brings it back.|, &shows_it_again/1},
      {"runs a sub-agent whose tokens count in the parent's",
       "V.agent/2 starts a sub-agent as a job; it passes its spending to the parent as it " <>
         "comes, and asks the parent what is left before each call.", &sub_agent/1},
      {"the agent never crashed", "The agent that started the phase is the one that ends it.",
       &Visor.Example.Offline.same_agent/1},
      {"spends within its limits, with no failed call",
       "Every live prompt ended without :budget, :model_error or :model_crashed, and the " <>
         "breaker stayed closed.", &no_failed_call/1}
    ]
  end

  defp fixes_the_bug(ctx) do
    tests = digest(ctx, "test/todo_app_test.exs")

    step =
      prompt(
        ctx,
        "Two tests in this project fail. Find out why, fix the code in lib/ (never the " <>
          "tests), and check that the tests pass.",
        steer: "Keep your final answer under 60 words."
      )

    # As the agent's own commands run: the code the model wrote can't read
    # the key, and a hang it left ends at the timeout.
    {status, output} =
      command(ctx, "mix test",
        env: [{"MIX_ENV", "test"}],
        label: "mix test (in the copy, after the prompt)"
      )

    all([
      ended(step, [:answered]),
      event(step, "a V.check call", &match?({:code_call, _id, %{name: :check}}, &1)),
      event(step, "the steering message", &match?({:steer, _text}, &1)),
      pass_if(status == 0, "mix test ended #{inspect(status)}: #{excerpt(output)}"),
      pass_if(digest(ctx, "test/todo_app_test.exs") == tests, "the model changed the tests")
    ])
  end

  defp wakes(ctx) do
    step =
      prompt(
        ctx,
        ~S|Start the shell command "sleep 3 && echo build finished" as a background job | <>
          ~S|with V.sh(command, background: true), then answer at once: don't wait for it.|,
        settle: 20_000
      )

    all([
      event(step, "the job's start", &match?({:job_start, %{kind: :shell}}, &1)),
      event(step, "the job's end", &match?({:job_end, %{status: :exited}}, &1)),
      event(step, "a wake that tells of the job", fn
        {:wake, text} -> text =~ "sleep 3"
        _other -> false
      end),
      ended(step, [:answered])
    ])
  end

  defp sees_a_picture(ctx) do
    part = Visor.Content.image("image/png", red_png())

    step =
      prompt(ctx, "What colour is this picture? Answer with one word.",
        pictures: [{"red.png", part}]
      )

    all([ended(step, [:answered]), answered(step, ~r/red/i)])
  end

  defp shows_it_again(ctx) do
    step =
      prompt(
        ctx,
        ~S|Look again at the picture I sent earlier, with V.image("picture:red.png"), | <>
          "and tell me its colour in one word."
      )

    pictures = conversation_pictures(ctx)
    record(ctx, :runtime, "messages with pictures in the conversation", :ok, inspect(pictures))

    all([
      ended(step, [:answered]),
      event(step, ~S|a V.image("picture:red.png") call|, fn e ->
        match?({:code_call, _id, %{name: :image, args: ["picture:red.png"], status: :ok}}, e)
      end),
      answered(step, ~r/red/i),
      pass_if(pictures == 1, "the conversation holds #{pictures} messages with pictures, not 1")
    ])
  end

  # The prompt's totals count the parent's own calls and, through the
  # job's end, the child's: the parent's spending must hold both. Its own
  # calls alone outweigh the child's, so less would mean the child's
  # never reached it.
  defp sub_agent(ctx) do
    step =
      prompt(
        ctx,
        ~S|Start a sub-agent with V.agent("List the public functions defined in | <>
          ~S|lib/todo_app.ex, one per line, and nothing else."), wait for it with | <>
          "V.wait, and tell me what it found."
      )

    child =
      Enum.find_value(step.events, fn
        {:job_end, %{kind: :agent} = job} -> job
        _other -> nil
      end)

    spent = Visor.Agent.settings(ctx.session).spent
    totals = (child && child[:totals]) || %{}
    child_tokens = (totals[:prompt_tokens] || 0) + (totals[:completion_tokens] || 0)
    both = step.totals.prompt_tokens + step.totals.completion_tokens

    record(
      ctx,
      :runtime,
      "the sub-agent's totals, the prompt's (the parent's calls and the child's), and " <>
        "the parent's spending",
      :ok,
      inspect(%{child: totals, prompt_tokens_with_child: both, parent_spent: spent}, pretty: true)
    )

    all([
      ended(step, [:answered]),
      pass_if(
        child && child.status == :exited,
        "no sub-agent ended as :exited (#{inspect(child && child.status)})"
      ),
      pass_if(child_tokens > 0, "the sub-agent's job counted no tokens"),
      pass_if(
        spent.tokens >= both,
        "the parent's prompt counted #{spent.tokens} tokens: its own calls and the " <>
          "sub-agent's come to #{both}"
      ),
      answered(step, ~r/complete|pending|summary/)
    ])
  end

  defp no_failed_call(ctx) do
    reasons = reasons(ctx)
    settings = Visor.Agent.settings(ctx.session)

    record(
      ctx,
      :runtime,
      "each live prompt's end, and Visor.Agent.settings(session)",
      :ok,
      inspect(%{reasons: reasons, spent: settings.spent, limits: settings.limits}, pretty: true)
    )

    failed = Enum.filter(reasons, &(&1 in [:budget, :model_error, :model_crashed]))

    cond do
      reasons == [] -> {:fail, "no live prompt ended"}
      failed != [] -> {:fail, "prompts ended with #{inspect(failed)}"}
      held = Visor.ModelHealth.open() -> {:fail, held}
      true -> :pass
    end
  end
end
