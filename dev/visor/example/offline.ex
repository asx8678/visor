defmodule Visor.Example.Offline do
  @moduledoc """
  `mix visor.example`'s checks without a model: scripts through the
  `elixir` tool, as the model's tool calls would run, and readings of
  Visor's state between them. They run in order on one copy of the
  example: the check that fixes the bug comes after the ones that need it.
  """

  import Visor.Example.Run

  # Planted in the VM's environment by the checks that hide secrets: those
  # named like one, and others that only look it.
  @planted %{
    "DEEPSEEK_VISOR_EXAMPLE" => "planted",
    "VISOR_EXAMPLE_API_KEY" => "planted",
    "VISOR_EXAMPLE_DB_PASSWORD" => "planted",
    "VISOR_EXAMPLE_SECRET_BASE" => "planted",
    "VISOR_EXAMPLE_TOKEN" => "planted",
    "VISOR_EXAMPLE_MONKEY" => "plain",
    "VISOR_EXAMPLE_TOKENIZERS" => "plain",
    "VISOR_EXAMPLE_PLAIN" => "plain"
  }

  # Those of them a command sees, by default.
  @shown ["VISOR_EXAMPLE_MONKEY", "VISOR_EXAMPLE_PLAIN", "VISOR_EXAMPLE_TOKENIZERS"]

  # The names of them a script's command sees, joined.
  @visible ~S"""
  V.sh("env | grep -E '^(DEEPSEEK_|VISOR_EXAMPLE_)'").output
  |> String.split("\n", trim: true)
  |> Enum.map(fn line -> line |> String.split("=") |> hd() end)
  |> Enum.sort()
  |> Enum.join(",")
  """

  @doc "The checks, as `{name, what, fun}` (see `Visor.Example.Run`)."
  @spec checks() :: [Visor.Example.Run.check()]
  def checks do
    Enum.concat([
      files(),
      refusals(),
      runner(),
      provider(),
      sandbox_exits(),
      repairs(),
      checking(),
      code(),
      jobs(),
      budget(),
      the_rest()
    ])
  end

  defp files do
    [
      {"lists the project", "V.ls/1 lists the workspace's top folder: the example's copy.",
       fn ctx -> ctx |> script(~S|V.ls()|) |> expect(:ok, ["lib/", "mix.exs", "test/"]) end},
      {"reads a file", "V.read/1 reads a file of the project.",
       fn ctx ->
         ctx
         |> script(~S|V.read("lib/todo_app.ex") =~ "defmodule TodoApp do"|)
         |> expect(:ok, ["=> true"])
       end},
      {"searches the code", "V.grep/2 finds a definition, with its file and line.",
       fn ctx ->
         ctx |> script(~S|V.grep("def complete", "lib")|) |> expect(:ok, ["lib/todo_app.ex"])
       end},
      {"finds files by pattern", "V.glob/1 and V.exists?/1.",
       fn ctx ->
         ctx
         |> script(~S"""
         {V.glob("**/*.exs") |> Enum.sort(), V.exists?("mix.exs"), V.exists?("nope.txt")}
         """)
         |> expect(:ok, ["test/todo_app_test.exs", "true, false}"])
       end},
      {"writes and edits a file", "V.write/2, then V.edit/3, read back.",
       fn ctx ->
         ctx
         |> script(~S"""
         V.write("notes.txt", "one\n")
         V.edit("notes.txt", "one", "two")
         V.read("notes.txt") == "two\n"
         """)
         |> expect(:ok, ["=> true"])
       end}
    ]
  end

  defp refusals do
    [
      {"refuses the .env file",
       "A script can't read .env, where the API key lives, and nothing of it shows.",
       fn ctx ->
         step = script(ctx, ~S|V.read(".env")|)
         all([expect(step, :error, [".env"]), refute_output(step, decoy())])
       end},
      {"refuses a path outside the project", "../ can't leave the workspace.",
       fn ctx ->
         step = script(ctx, ~S|V.read("../../../mix.exs")|)
         all([expect(step, :error, []), refute_output(step, "Visor.MixProject")])
       end},
      {"keeps the sandbox closed",
       "A script reaches the project through V only: File.read!/1 itself is refused.",
       fn ctx -> ctx |> script(~S|File.read!("mix.exs")|) |> expect(:error, []) end},
      {"hides the key and other secrets from shell commands",
       "A command's environment has no DEEPSEEK_ settings, nor variables named like a key, " <>
         "a token, a secret or a password (planted for the check); MONKEY, TOKENIZERS and " <>
         "the rest stay.",
       fn ctx ->
         with_planted_env(:default, fn ->
           ctx |> script(@visible) |> expect(:ok, [~s("#{Enum.join(@shown, ",")}")])
         end)
       end},
      {"hides what config :hidden_env names, and the model's settings still",
       "With the pattern set to one name, that name and the DEEPSEEK_ ones are hidden, and " <>
         "the secrets the default would hide show.",
       fn ctx ->
         with_planted_env("^VISOR_EXAMPLE_PLAIN$", fn ->
           shown =
             Enum.sort(Map.keys(@planted) -- ["DEEPSEEK_VISOR_EXAMPLE", "VISOR_EXAMPLE_PLAIN"])

           ctx |> script(@visible) |> expect(:ok, [~s("#{Enum.join(shown, ",")}")])
         end)
       end}
    ]
  end

  # The runner's own commands, as the live phase reruns mix test on the
  # code the model wrote.
  defp runner do
    [
      {"runs its own commands as the agent's run",
       "Run.command/3 hides the DEEPSEEK_ settings and the secrets, and sets the :env it is " <>
         "given, a name the pattern would hide included.",
       fn ctx ->
         with_planted_env(:default, fn ->
           {status, output} =
             command(ctx, "env | grep -E '^(DEEPSEEK_|VISOR_EXAMPLE_)'",
               env: [{"VISOR_EXAMPLE_GIVEN_TOKEN", "given"}]
             )

           shown = Enum.sort(["VISOR_EXAMPLE_GIVEN_TOKEN" | @shown])

           all([
             pass_if(status == 0, "it ended #{inspect(status)}: #{excerpt(output)}"),
             pass_if(names(output) == shown, "it shows #{inspect(names(output))}")
           ])
         end)
       end},
      {"records a sub-agent's events from its first",
       "The recorder has every session's events from the first, with no watch for the " <>
         "session: a sub-agent's under its parent's label and its job.",
       fn ctx ->
         child =
           Task.async(fn ->
             {:ok, child} =
               Visor.Harness.start_session(self(),
                 label: "example recorded",
                 depth: 1,
                 parent: "#{ctx.session}/j99"
               )

             {:ok, _settings} = Visor.Agent.configure(child, jobs_wake: false)
             child
           end)
           |> Task.await(10_000)

         Visor.Example.Recorder.sync(ctx.run.recorder)
         lines = recorded(ctx, child)
         labels = lines |> Enum.map(& &1["label"]) |> Enum.uniq()
         named = {child, "offline/j99"} in Visor.Example.Recorder.sessions(ctx.run.recorder)

         record(
           ctx,
           :runtime,
           "events.jsonl's lines of the sub-agent #{child}",
           :ok,
           Enum.map_join(lines, "\n", &"#{&1["label"]} #{&1["event"]}")
         )

         all([
           pass_if(Enum.any?(lines, &(&1["event"] == "settings")), "no settings event of it"),
           pass_if(labels == ["offline/j99"], "its events' labels: #{inspect(labels)}"),
           pass_if(named, "Recorder.sessions/1 lacks it")
         ])
       end},
      {"stops its own command at its timeout",
       "A command that hangs ends at :timeout, and what it started dies with it.",
       fn ctx ->
         {status, _output} = command(ctx, "sleep 47", timeout: 300)

         all([
           pass_if(status == :timeout, "it ended #{inspect(status)}, not :timeout"),
           pass_if(gone?("sleep 47"), "sleep 47 still runs 2 s later")
         ])
       end}
    ]
  end

  # A sub-agent's spending held to its parent's. A prompt over its limit
  # stops before its model call, so these make none.
  defp budget do
    [
      {"a sub-agent holds to its parent's last answer when the parent is slow",
       "A sub-agent whose parent has nothing left stops before its model call (:budget); " <>
         "prompted again while the parent can't answer, it holds to that answer, says so " <>
         "and stops again, instead of spending the limits it started with.", &slow_parent/1}
    ]
  end

  defp slow_parent(ctx) do
    # Were a model call made after all, it would find nothing listening.
    {first, second, ms} =
      with_env("DEEPSEEK_BASE_URL", "http://127.0.0.1:9", fn ->
        Task.async(&slow_parent_run/0) |> Task.await(60_000)
      end)

    record(
      ctx,
      :runtime,
      "a sub-agent's two prompts, the second with its parent suspended",
      :ok,
      inspect(%{first: first, second: second, second_ms: ms}, pretty: true)
    )

    all([
      pass_if(ended(first) == :budget, "the first prompt ended #{inspect(ended(first))}"),
      pass_if(
        ended(second) == :budget,
        "with the parent slow, the second prompt ended #{inspect(ended(second))}"
      ),
      pass_if(
        Enum.any?(second, &match?({:note, :info, "Its parent session didn't" <> _}, &1)),
        "no note said the parent didn't answer"
      ),
      pass_if(
        not Enum.any?(first ++ second, &match?({:turn_start, _}, &1)),
        "a model call started"
      ),
      pass_if(ms >= 900, "the second prompt didn't wait for the parent (#{ms} ms)")
    ])
  end

  # In a task of its own: it owns both sessions, so they stop with it, and
  # its mailbox has the sub-agent's events alone. The sub-agent starts with
  # what its parent had left, as V.agent starts one; then the parent's
  # prompt spends all of it.
  defp slow_parent_run do
    {:ok, parent} = Visor.Harness.start_session(self(), label: "example slow parent")
    left = Visor.Agent.allowance(parent)

    {:ok, child} =
      Visor.Harness.start_session(self(),
        label: "example sub-agent of #{parent}",
        depth: 1,
        budget_parent: parent,
        limits: left
      )

    :ok = Visor.Agent.subscribe(child)
    Visor.Agent.spent(parent, left.prompt, 0)
    # After the cast, so the parent has counted it.
    _ = Visor.Agent.allowance(parent)
    first = prompt_events(child)

    agent = agent_pid(parent)
    :ok = :sys.suspend(agent)
    started = System.monotonic_time(:millisecond)

    try do
      second = prompt_events(child)
      {first, second, System.monotonic_time(:millisecond) - started}
    after
      :sys.resume(agent)
    end
  end

  # The events of one prompt of `id`, to its end.
  defp prompt_events(id) do
    :ok = Visor.Agent.prompt(id, "Say hello.")
    collect_prompt([])
  end

  defp collect_prompt(acc) do
    receive do
      {:agent, {:prompt_end, _info} = event} -> Enum.reverse([event | acc])
      {:agent, event} -> collect_prompt([event | acc])
    after
      15_000 -> Enum.reverse([{:prompt_end, %{reason: :no_end_in_15_s}} | acc])
    end
  end

  defp ended(events) do
    Enum.find_value(events, fn
      {:prompt_end, %{reason: reason}} -> reason
      _other -> nil
    end)
  end

  # `name` set to `value` while `fun` runs, then put back.
  defp with_env(name, value, fun) do
    previous = System.get_env(name)
    System.put_env(name, value)

    try do
      fun.()
    after
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end
  end

  # The DeepSeek client's reading of the provider's refusals, against a
  # local stand-in (Visor.Example.StatusPlug).
  defp provider do
    [
      {"reads the provider's refusals",
       "A 413, or a 400 that names the window, is too large (:context_overflow: compact and " <>
         "retry); any other 400, or a 422, is :rejected (not the provider's health); a 401 " <>
         "is a failure.",
       fn ctx ->
         {:ok, server} =
           Bandit.start_link(
             plug: Visor.Example.StatusPlug,
             ip: {127, 0, 0, 1},
             port: 0,
             startup_log: false
           )

         {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

         got =
           try do
             for kind <- ["413", "400-window", "400", "422", "401"] do
               with_env("DEEPSEEK_API_KEY", "not-a-real-key", fn ->
                 with_env("DEEPSEEK_BASE_URL", "http://127.0.0.1:#{port}/#{kind}", fn ->
                   {kind,
                    refusal(Visor.Model.DeepSeek.stream(provider_request(), fn _ -> :ok end))}
                 end)
               end)
             end
           after
             Supervisor.stop(server)
           end

         record(
           ctx,
           :runtime,
           "Visor.Model.DeepSeek.stream/2 against each status",
           :ok,
           inspect(got)
         )

         expected = [
           {"413", :context_overflow},
           {"400-window", :context_overflow},
           {"400", :rejected},
           {"422", :rejected},
           {"401", :failed}
         ]

         pass_if(got == expected, "it read them as #{inspect(got)}")
       end}
    ]
  end

  defp provider_request do
    %{
      system: "A check.",
      messages: [%{"role" => "user", "content" => "Hello."}],
      tools: [],
      tool_choice: "auto",
      effort: "high",
      thinking: false
    }
  end

  defp refusal({:error, kind, _message}) when kind in [:context_overflow, :rejected], do: kind
  defp refusal({:error, message}) when is_binary(message), do: :failed
  defp refusal(other), do: {:unexpected, other}

  # A call the sandbox allows that exits with a reason that isn't an
  # exception's (the Dune fork's fix, 59dccd0).
  defp sandbox_exits do
    [
      {"fails a script whose call exits, instead of crashing",
       "An allowed call that exits with :boom, {:shutdown, []} or a Task.await's timeout fails " <>
         "the script with the reason; the process that ran it lives on.",
       fn ctx ->
         reasons = [:boom, {:shutdown, []}, {:timeout, {Task, :await, [:ref, 5000]}}]

         got =
           for reason <- reasons do
             code = "Visor.Example.Exits.exit_with(#{inspect(reason)})"

             task =
               Task.Supervisor.async_nolink(Visor.Harness.via({ctx.session, :tasks}), fn ->
                 Dune.eval_string(code, allowlist: Visor.Example.ExitAllowlist, timeout: 5_000)
               end)

             case Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill) do
               {:ok, %Dune.Failure{type: :exception, message: message}} -> {:failed, message}
               {:ok, other} -> {:unexpected, other}
               {:exit, reason} -> {:crashed, Exception.format_exit(reason)}
               nil -> :timeout
             end
           end

         record(
           ctx,
           :runtime,
           "Dune.eval_string/2 of calls that exit",
           :ok,
           inspect(got, pretty: true)
         )

         pass_if(
           Enum.all?(got, &match?({:failed, "** (exit) " <> _}, &1)),
           "not each failed with its reason: #{inspect(got)}"
         )
       end}
    ]
  end

  # @planted in the VM's environment while `fun` runs, and config :visor,
  # :hidden_env set to `pattern` (:default: unset), both put back after.
  defp with_planted_env(pattern, fun) do
    previous = Application.fetch_env(:visor, :hidden_env)
    System.put_env(@planted)

    if pattern == :default,
      do: Application.delete_env(:visor, :hidden_env),
      else: Application.put_env(:visor, :hidden_env, pattern)

    try do
      fun.()
    after
      Enum.each(Map.keys(@planted), &System.delete_env/1)

      case previous do
        {:ok, value} -> Application.put_env(:visor, :hidden_env, value)
        :error -> Application.delete_env(:visor, :hidden_env)
      end
    end
  end

  # The variables' names in `env` output.
  defp names(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line -> line |> String.split("=") |> hd() end)
    |> Enum.sort()
  end

  # Whether no process runs `pattern`, within 2 s: the shell's watchdog
  # kills what a command started once its port closes, not at once.
  defp gone?(pattern, tries \\ 20) do
    case System.cmd("pgrep", ["-f", pattern]) do
      {_none, 1} ->
        true

      _running when tries > 0 ->
        Process.sleep(100)
        gone?(pattern, tries - 1)

      _running ->
        false
    end
  end

  defp repairs do
    [
      {"puts a Python-style heredoc right",
       "A heredoc whose text starts on its opening line is read as meant " <>
         "(Visor.Tools.Heredoc), and the repair is told as an event.",
       fn ctx ->
         step = script(ctx, ~s[text = """hello there"""\nString.upcase(text)])

         all([
           expect(step, :ok, ["HELLO THERE"]),
           event(step, "a repair event", &match?({:repair, %{reason: :arguments}}, &1))
         ])
       end},
      {"takes code given under another key", ~S|{"script": ...} is read as {"code": ...}.|,
       fn ctx ->
         step = script(ctx, nil, raw: ~s[{"script": "1 + 1"}])

         all([
           expect(step, :ok, ["=> 2"]),
           event(step, "a repair event", &match?({:repair, %{reason: :arguments}}, &1))
         ])
       end}
    ]
  end

  defp checking do
    [
      {"runs a shell command", "V.sh/1 runs a command in the project and returns its output.",
       fn ctx ->
         ctx
         |> script(~S|V.sh("echo hello from sh").output =~ "hello from sh"|)
         |> expect(:ok, ["=> true"])
       end},
      {"checks the project: the bug fails its tests",
       "V.check/0 runs mix test in the copy and reports what failed.",
       fn ctx -> ctx |> script(~S|V.check()|) |> expect(:ok, ["failed", "marks an item done"]) end},
      {"puts a wrong fix back",
       "V.attempt/2 keeps edits only if the check passes: a fix that doesn't is undone.",
       fn ctx ->
         ctx
         |> script(~S"""
         r =
           V.attempt(
             fn -> V.edit("lib/todo_app.ex", "%{item | done: false}", "%{item | done: nil}") end,
             check: "test"
           )

         {r.status, V.read("lib/todo_app.ex") =~ "%{item | done: false}"}
         """)
         |> expect(:ok, ["{:reverted, true}"])
       end},
      {"fixes the bug, and the check passes", "V.edit/3, then V.check/0.",
       fn ctx ->
         ctx
         |> script(~S"""
         V.edit("lib/todo_app.ex", "%{item | done: false}", "%{item | done: true}")
         V.check().status
         """)
         |> expect(:ok, ["=> :ok"])
       end}
    ]
  end

  defp code do
    [
      {"reads docs and source from the compiled code",
       "V.docs/1 and V.source/1 read the project's .beam files, never loaded.",
       fn ctx ->
         ctx
         |> script(~S"""
         {inspect(V.docs("TodoApp.add")) =~ "Adds an item",
          inspect(V.source("TodoApp.add/2")) =~ "todo_app.ex"}
         """)
         |> expect(:ok, ["{true, true}"])
       end},
      {"finds call sites", "V.calls/2 finds where TodoApp.add/2 is called.",
       fn ctx ->
         ctx
         |> script(~S|inspect(V.calls("TodoApp.add/2")) =~ "store.ex"|)
         |> expect(:ok, ["=> true"])
       end},
      {"runs read-only calls at once", "V.all/1: one result per call, a failure among them.",
       fn ctx ->
         ctx
         |> script(~S"""
         V.all([{:read, ["mix.exs"]}, {:ls, ["lib"]}, {:read, ["nope.txt"]}])
         |> Enum.map(&elem(&1, 0))
         """)
         |> expect(:ok, ["[:ok, :ok, :error]"])
       end}
    ]
  end

  defp jobs do
    [
      {"runs a background job",
       "V.sh(cmd, background: true) returns at once, V.wait/1 gets its end, and the " <>
         "console hears job_end.",
       fn ctx ->
         start = script(ctx, ~S|V.sh("sleep 0.3; echo job done", background: true)|)

         with :pass <- expect(start, :ok, [~r/job: "j\d+"/]) do
           id = job_id(start)
           wait = script(ctx, ~s|w = V.wait("#{id}")\n{w.status, w.tail =~ "job done"}|)

           all([
             expect(wait, :ok, ["{:exited, true}"]),
             await_event(ctx, "its job_end", fn e -> match?({:job_end, %{id: ^id}}, e) end)
           ])
         end
       end},
      {"monitors a job's lines",
       "V.sh(cmd, monitor: text): the lines with the text are held for the agent while it " <>
         "runs, and told with its end.",
       fn ctx ->
         start =
           script(
             ctx,
             ~S|V.sh("for i in 1 2 3; do echo tick $i; sleep 0.1; done; echo READY now", monitor: "READY")|
           )

         # Not V.wait: a script that reads a job's end has heard of it, and
         # the agent's notice of it goes.
         with :pass <- expect(start, :ok, [~r/job: "j\d+"/]),
              id = job_id(start),
              :pass <-
                await_event(ctx, "its job_end", fn e -> match?({:job_end, %{id: ^id}}, e) end) do
           :ok = Visor.Jobs.sync(ctx.session)
           job = Visor.Jobs.get(ctx.session, id)
           notice = job && Visor.Jobs.take_notice(ctx.session, job)
           record(ctx, :runtime, "Visor.Jobs.take_notice(session, job)", :ok, inspect(notice))

           pass_if(
             is_binary(notice) and notice =~ "READY now" and not (notice =~ "tick 1"),
             "the agent's notice of the job lacks its READY line: #{inspect(notice)}"
           )
         end
       end},
      {"stops a job", "V.stop/1 ends a running job, which ends as :killed.",
       fn ctx ->
         start = script(ctx, ~S|V.sh("sleep 30", background: true)|)

         with :pass <- expect(start, :ok, [~r/job: "j\d+"/]) do
           id = job_id(start)
           stop = script(ctx, ~s|V.stop("#{id}").status|)

           all([
             expect(stop, :ok, [":killed"]),
             await_event(ctx, "its job_end as killed", fn e ->
               match?({:job_end, %{id: ^id, status: :killed}}, e)
             end)
           ])
         end
       end}
    ]
  end

  defp the_rest do
    [
      {"looks at a picture in the project", "V.image/1 holds red.png for the next model call.",
       fn ctx -> ctx |> script(~S|V.image("red.png")|) |> expect(:ok, ["attached", "red.png"]) end},
      {"refuses a picture the user never sent",
       ~S|V.image("picture:NAME") shows only what the user sent.|,
       fn ctx ->
         ctx |> script(~S|V.image("picture:nope.png")|) |> expect(:error, ["keeps no picture"])
       end},
      {"keeps notes for later sessions",
       "V.remember/1, V.memories/0 and V.forget/1, in the project's .visor/memory.md.",
       fn ctx ->
         ctx
         |> script(~S"""
         V.remember("The example's bug was in complete/2.")
         kept = inspect(V.memories()) =~ "complete/2"
         V.forget("The example's bug was in complete/2.")
         {kept, inspect(V.memories()) =~ "complete/2"}
         """)
         |> expect(:ok, ["{true, false}"])
       end},
      {"saves a script and runs it again", "V.save/3, then V.run/1.",
       fn ctx ->
         ctx
         |> script(~S"""
         V.save("count_lib_files", ~S|length(V.glob("lib/**/*.ex"))|, "Counts lib's .ex files.")
         V.run("count_lib_files")
         """)
         |> expect(:ok, ["=> 2"])
       end},
      {"keeps a prompt's variables", "A prompt's scripts share their variables (a Dune.Session).",
       fn ctx ->
         first = script(ctx, "answer = 41", dune: Dune.Session.new())
         second = script(ctx, "answer + 1", dune: first.dune)
         expect(second, :ok, ["=> 42"])
       end},
      {"tells how full the context is", "V.context/0, before any model call.",
       fn ctx ->
         ctx
         |> script(~S"""
         V.context() |> Map.keys() |> Enum.sort()
         """)
         |> expect(:ok, ["tokens", "threshold"])
       end},
      {"shows a progress note", "V.note/1 reaches the console as an event, not the result.",
       fn ctx ->
         step = script(ctx, "V.note(\"halfway there\")\n:done")

         all([
           expect(step, :ok, ["=> :done"]),
           event(step, "a script_note event", &match?({:script_note, _id, "halfway there"}, &1))
         ])
       end},
      {"the breaker and the alarms are quiet",
       "Visor.ModelHealth and Visor.Alarms hold nothing back.",
       fn ctx ->
         held = {Visor.ModelHealth.open(), Visor.Alarms.held()}

         record(
           ctx,
           :runtime,
           "{Visor.ModelHealth.open(), Visor.Alarms.held()}",
           :ok,
           inspect(held)
         )

         pass_if(held == {nil, nil}, "held: #{inspect(held)}")
       end},
      {"writes the session log",
       "Visor.SessionLog writes the session's events to its folder (an offline run's own).",
       &session_log/1},
      {"the agent never crashed", "The agent that started the phase is the one that ends it.",
       &same_agent/1},
      {"the agent is idle and within its limits",
       "Visor.Agent.settings/1 after the scripts: no prompt ran.",
       fn ctx ->
         settings = Visor.Agent.settings(ctx.session)

         record(
           ctx,
           :runtime,
           "Visor.Agent.settings(session)",
           :ok,
           inspect(settings, pretty: true)
         )

         pass_if(
           settings.status == :idle and settings.spent.session == 0,
           "status #{settings.status}, spent #{inspect(settings.spent)}"
         )
       end}
    ]
  end

  @doc false
  # Shared with Visor.Example.Live: a crash restarts the agent with its
  # conversation, so nothing else might show it.
  def same_agent(ctx) do
    now = agent_pid(ctx.session)
    record(ctx, :runtime, "the agent's pid, then and now", :ok, inspect({ctx.agent, now}))
    pass_if(now == ctx.agent, "the agent restarted: #{inspect(ctx.agent)} is now #{inspect(now)}")
  end

  # The session log writes each event as it comes, from a process of its
  # own: its file has the scripts' calls within moments.
  defp session_log(ctx, tries \\ 40) do
    case Path.wildcard(Path.join(Visor.SessionLog.dir(), "*-#{ctx.session}.jsonl")) do
      [path | _] ->
        text = File.read!(path)

        if not (text =~ "code_call") and tries > 0 do
          Process.sleep(50)
          session_log(ctx, tries - 1)
        else
          check_log(ctx, path, text)
        end

      [] when tries > 0 ->
        Process.sleep(50)
        session_log(ctx, tries - 1)

      [] ->
        {:fail, "no #{Visor.SessionLog.dir()}/*-#{ctx.session}.jsonl"}
    end
  end

  defp check_log(ctx, path, text) do
    path = Path.relative_to(path, ctx.run.root)
    record(ctx, :runtime, "File.read!(#{path})", :ok, excerpt(text, 600))
    pass_if(text =~ "code_call", "#{path} has no code_call line")
  end
end
