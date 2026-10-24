defmodule V do
  @moduledoc """
  The functions an `elixir` tool script calls (see `Visor.Code`).

  Each call runs inside the script's process and shows up in the console
  under the script. Paths are relative to the project root. A failing
  call raises `V.Error`, which stops the script and returns the error to
  the model.

  Each call also reports to the script's runner, which sums the calls up
  for the model when the script ends (see `Visor.Feedback.Script`).
  """

  alias Visor.{Check, Code, Feedback, Format, Jobs, Limits, Lock, Observer, Tools, Workspace}

  defmodule Error do
    defexception [:message]
  end

  @doc false
  # Prepended to every script by Visor.Code: finds the runner's context
  # and names the script's processes for the process view.
  def __begin__ do
    [sandbox | ancestors] = Process.get(:"$ancestors", [nil])
    Process.put(Code, Enum.find_value(ancestors, &Code.context/1))
    Process.set_label("elixir script")
    Visor.Observer.label(self(), "elixir script")
    if is_pid(sandbox), do: Visor.Observer.label(sandbox, "sandbox")
    nil
  end

  @doc "Names in a folder, sorted; folders end in /."
  def ls(path \\ ".") when is_binary(path), do: track(:ls, [path], fn -> Tools.list(path) end)

  @doc "Paths matching a wildcard such as `lib/**/*.ex`."
  def glob(pattern) when is_binary(pattern),
    do: track(:glob, [pattern], fn -> Tools.glob(pattern) end)

  @doc """
  Whether a file or folder exists. Scripts can't rescue a failing call, so
  this is how a script reads a file only if it's there.
  """
  def exists?(path) when is_binary(path),
    do: track(:exists?, [path], fn -> Tools.exists(path) end)

  @doc "A text file's contents (up to `Visor.Limits.read_bytes/0`)."
  def read(path) when is_binary(path),
    do: track(:read, [path], fn -> Tools.read(path) end)

  @doc """
  Lines matching a regular expression, given as a string or a `~r` regex,
  as `%{file: path, line: n, text: line}`.
  """
  def grep(pattern, path \\ ".")

  def grep(pattern, path)
      when (is_binary(pattern) or is_struct(pattern, Regex)) and is_binary(path),
      do: track(:grep, [pattern, path], fn -> Tools.search(pattern, path) end)

  def grep(pattern, path) do
    raise Error,
          "V.grep takes a regex, as a string or ~r//, and a path string, " <>
            "not #{inspect(pattern)} and #{inspect(path)}."
  end

  @doc "Writes a file, creating its folder if needed."
  def write(path, contents) when is_binary(path) and is_binary(contents) do
    track(:write, [path, contents], fn -> change(path, fn -> Tools.write(path, contents) end) end)
  end

  @doc "Replaces the one occurrence of `old` in a file with `new`."
  def edit(path, old, new) when is_binary(path) and is_binary(old) and is_binary(new) do
    track(:edit, [path, old, new], fn -> change(path, fn -> Tools.edit(path, old, new) end) end)
  end

  @doc """
  Runs a shell command in the project folder. `status` is the exit code,
  or `:timeout`. The output of a failed command is kept, so the script's
  result can point to it.

  `timeout:` (seconds) raises its time limit from
  `Visor.Limits.shell_timeout_ms/0`. A command never runs past its
  script's own limit: it times out a second before.

  `background: true` runs it as a job instead (see `Visor.Jobs`) and
  returns `%{job: id, log: path}` at once. A job isn't bound by its
  script: its limit is `Visor.Limits.job_timeout_ms/0`, or `timeout:`
  up to `max_job_timeout_ms/0`. When it ends, the model hears of it.
  """
  def sh(command, opts \\ [])

  def sh(command, opts) when is_binary(command) and is_list(opts) do
    if Keyword.get(opts, :background, false),
      do: background(command, opts),
      else: foreground(command, opts)
  end

  defp background(command, opts) do
    not_in_attempt("A background job")

    timeout =
      opts
      |> asked_timeout(Limits.job_timeout_ms(), [:timeout, :background])
      |> min(Limits.max_job_timeout_ms())

    track(:sh, [command, opts], fn ->
      with {:ok, job} <- with_jobs(&Jobs.start_shell(&1, command, timeout)) do
        {:ok, %{job: job.id, log: job.log}, %{started: job.id}}
      end
    end)
  end

  defp foreground(command, opts) do
    timeout = within_script(opts, Limits.shell_timeout_ms(), 1_000, [:timeout, :background])

    track(:sh, [command | opts_args(opts)], fn ->
      {status, output} = Tools.shell(command, timeout: timeout)
      ref = if status != 0, do: Feedback.keep(session(), output)
      {:ok, %{status: status, output: output}, %{ran: command, exit: status, ref: ref}}
    end)
  end

  @doc """
  Compiles the project and runs its tests, or only the tests at `path`
  (such as `"test/app_test.exs:12"`), in one `mix test`. Returns
  `%{status: :ok | :failed | :compile_error | :timeout | :error, ...}`;
  the script's result shows what failed (see `Visor.Check`).

  `timeout:` (seconds) raises its time limit from
  `Visor.Limits.check_timeout_ms/0`, within the script's own limit, as
  for `sh/2`. `V.check(timeout: 300)` checks the whole project.
  """
  def check(path \\ nil, opts \\ [])

  def check(opts, []) when is_list(opts), do: check(nil, opts)

  def check(path, opts) when (is_nil(path) or is_binary(path)) and is_list(opts) do
    timeout = within_script(opts, Limits.check_timeout_ms(), 5_000)

    track(:check, List.wrap(path) ++ opts_args(opts), fn ->
      session = session()
      changed = Feedback.changed_files(session)
      root = Workspace.root()
      stats = Map.new(changed, &{&1, stat(Path.join(root, &1))})

      with {:ok, check, output} <- Check.run(path, timeout) do
        # What mix test saw of the changed files (see change/2).
        Feedback.saw(session, stats)
        previous = Feedback.record_check(session, path, check)
        # An attempt that puts its files back puts this record back too.
        if Process.get(:visor_attempt_check),
          do: Process.put(:visor_attempt_check, {path, previous})

        ref = if check.status != :ok, do: Feedback.keep(session, output)
        summary = Check.render(check, previous, changed, ref)
        result = Check.result(check)
        {:ok, result, %{check: summary, value: result}}
      end
    end)
  end

  @doc """
  Background job `id` (see `sh/2`): its `status` (`:running`, `:exited`,
  `:failed`, `:killed` or `:timed_out`), `exit` code, `ms` so far, `log`
  file and the end of its output (`tail`). Reading a job that ended
  counts as hearing of it.
  """
  def job(id) when is_binary(id) do
    track(:job, [id], fn ->
      with {:ok, job} <- find_job(id) do
        if job.status != :running, do: Jobs.acknowledge(session(), id)
        {:ok, job_view(job)}
      end
    end)
  end

  @doc """
  Starts a sub-agent on `task` as a background job, and returns
  `%{job: id}` at once: an agent of its own, with a fresh context, that
  works on the task and answers. You hear its answer when it is done, as
  for any job; `V.output(id)` has all of it. Options: `seed: :snippet`
  passes it the last messages of this conversation as context (by
  default it gets the task alone), `role:` says what it is for,
  `max_steps:` (up to #{Limits.agent_steps()} by default) and `timeout:`
  (seconds). A sub-agent can't start one of its own.

  `seed: :snippet` sends the conversation's text to the sub-agent as it
  is, including anything secret a file read put in it.
  """
  def agent(task, opts \\ []) when is_binary(task) and is_list(opts) do
    not_in_attempt("A sub-agent")

    track(:agent, [task | opts_args(opts)], fn ->
      with {:ok, session} <- job_session(),
           {:ok, prompt, settings} <- agent_settings(session, task, opts) do
        with {:ok, job} <- Jobs.start_agent(session, prompt, settings) do
          {:ok, %{job: job.id}, %{started: job.id}}
        end
      end
    end)
  end

  @doc """
  Starts a council on `task`: one sub-agent per role in `roles:` (up to
  #{Limits.agents_at_once()}), all at once, each answering on its own;
  then, with `synthesize: true` (the default), one more that weighs their
  answers and gives one. Returns `%{job: id}` at once; you hear the
  council's answer when it is done, and `V.output(id)` has all of it.
  `max_steps:` and `timeout:` (seconds) apply to each member.
  """
  def council(task, opts) when is_binary(task) and is_list(opts) do
    not_in_attempt("A council")

    track(:council, [task | opts_args(opts)], fn ->
      roles = Keyword.get(opts, :roles, [])

      cond do
        Keyword.keys(opts) -- [:roles, :synthesize, :max_steps, :timeout] != [] ->
          {:error, "V.council's options are roles:, synthesize:, max_steps: and timeout:."}

        roles == [] or not Enum.all?(roles, &is_binary/1) ->
          {:error,
           ~s|V.council needs roles: as a list of strings, such as ["security reviewer"].|}

        true ->
          with {:ok, session} <- job_session(),
               {:ok, _prompt, settings} <-
                 agent_settings(session, task, Keyword.take(opts, [:max_steps, :timeout])),
               {:ok, job} <-
                 Jobs.start_council(
                   session,
                   task,
                   Map.merge(settings, %{
                     roles: roles,
                     synthesize: Keyword.get(opts, :synthesize, true)
                   })
                 ) do
            {:ok, %{job: job.id}, %{started: job.id}}
          end
      end
    end)
  end

  # What goes on running after its call returns can't start inside an
  # attempt, which may put its files back under it.
  defp not_in_attempt(what) do
    if Process.get(:visor_attempt) do
      raise Error,
            "#{what} can't start inside V.attempt: it would go on running against files " <>
              "the attempt may put back."
    end
  end

  defp agent_settings(session, task, opts) do
    allowed = [:seed, :role, :max_steps, :timeout]

    cond do
      Keyword.keys(opts) -- allowed != [] ->
        {:error, "V.agent's options are seed:, role:, max_steps: and timeout:."}

      Keyword.get(opts, :seed, :task) not in [:task, :snippet] ->
        {:error, "seed: is :task or :snippet."}

      not match?(n when is_integer(n) and n in 1..24, Keyword.get(opts, :max_steps, 1)) ->
        {:error, "max_steps: is a whole number from 1 to 24."}

      true ->
        prompt =
          if Keyword.get(opts, :seed) == :snippet,
            do: snippet(session) <> "\n\nYour task: " <> task,
            else: task

        timeout =
          case Keyword.get(opts, :timeout) do
            s when is_number(s) and s > 0 -> min(round(s * 1000), Limits.max_job_timeout_ms())
            _ -> Limits.agent_timeout_ms()
          end

        {:ok, prompt,
         %{
           task: task,
           role: Keyword.get(opts, :role, "a helper"),
           max_steps: Keyword.get(opts, :max_steps, Limits.agent_steps()),
           timeout_ms: timeout
         }}
    end
  end

  # The conversation's last words, text only: what a seeded sub-agent
  # knows of it.
  defp snippet(session) do
    messages =
      with store when store != nil <- Visor.Harness.Session.store(session),
           [{:conversation, %{messages: messages}}] <- :ets.lookup(store, :conversation) do
        messages
      else
        _ -> []
      end

    lines =
      messages
      |> Enum.filter(
        &(&1["role"] in ["user", "assistant"] and is_binary(&1["content"]) and &1["content"] != "")
      )
      |> Enum.take(-12)
      |> Enum.map_join("\n\n", fn message ->
        text = String.slice(message["content"], 0, 4000)
        "#{message["role"]}: #{text}"
      end)

    "<inherited-conversation>\n#{lines}\n</inherited-conversation>"
  end

  @doc "The session's background jobs, without their output."
  def jobs do
    track(:jobs, [], fn ->
      with {:ok, session} <- job_session() do
        {:ok, for(job <- Jobs.list(session), do: Map.delete(job_view(job), :tail))}
      end
    end)
  end

  @doc "Stops background job `id` and what it started."
  def stop(id) when is_binary(id) do
    track(:stop, [id], fn ->
      with {:ok, job} <- with_jobs(&Jobs.stop(&1, id)), do: {:ok, job_view(job)}
    end)
  end

  @doc """
  Waits for background job `id` to end, up to `timeout:` seconds (by
  default, and at most, what the script has left), and returns it as
  `job/1` does, ended or not. Starting a job and waiting for it in one
  script is a foreground command; `wait` is for a job started earlier.
  """
  def wait(id, opts \\ []) when is_binary(id) and is_list(opts) do
    left = max((Code.time_left() || Limits.script_timeout_ms()) - 2_000, 0)
    timeout = opts |> asked_timeout(left, [:timeout]) |> min(left)

    track(:wait, [id | opts_args(opts)], fn ->
      with {:ok, job} <- with_jobs(&Jobs.wait(&1, id, timeout)) do
        if job.status != :running, do: Jobs.acknowledge(session(), id)
        {:ok, job_view(job)}
      end
    end)
  end

  @doc """
  Shows `text` under this script's step in the console, as a progress
  note, and writes it to the session log. It isn't part of the script's
  result, so the model doesn't see it again. At most
  `Visor.Limits.script_notes/0` a script; each is cut to 300 characters.
  """
  def note(text) when is_binary(text) do
    n = Process.get(:visor_notes, 0) + 1
    Process.put(:visor_notes, n)

    with true <- n <= Limits.script_notes(),
         %{session: session, call_id: call_id} <- Process.get(Code) do
      text = if String.length(text) > 300, do: String.slice(text, 0, 300) <> "…", else: text
      Visor.Agent.Event.broadcast(session, {:script_note, call_id, text})
    end

    :ok
  end

  @doc """
  Saves `code` as a script named `name` (lowercase letters, digits, dots,
  dashes and underscores), to run again with `run/2` or the console's
  `/run name`. Saving the same name again replaces it.
  """
  def save(name, code, description \\ "")
      when is_binary(name) and is_binary(code) and is_binary(description) do
    track(:save, [name], fn ->
      with {:ok, script} <- Visor.Scripts.save(name, code, description) do
        {:ok, %{name: script.name, digest: String.slice(script.digest, 0, 12)}}
      end
    end)
  end

  @doc "The saved scripts: their names, descriptions and digests."
  def scripts do
    track(:scripts, [], fn ->
      {:ok, for(s <- Visor.Scripts.list(), do: Map.take(s, [:name, :description, :digest]))}
    end)
  end

  @doc """
  Runs saved script `name`, with `input` bound to the variable `input`,
  and returns its value. It runs within this script's time, and its V
  calls count as its own; a saved script can't run another.
  """
  def run(name, input \\ nil) when is_binary(name) do
    track(:run, [name | if(input == nil, do: [], else: [input])], fn ->
      context = Process.get(Code)

      with :ok <- not_nested(context),
           {:ok, script} <- Visor.Scripts.get(name) do
        left = Code.time_left() || Limits.script_timeout_ms()

        inner =
          Map.merge(context || %{}, %{
            saved: name,
            call_id: "#{context[:call_id]}/#{name}",
            timeout_ms: max(left - 2_000, 1_000)
          })

        code =
          "input = #{inspect(input, limit: :infinity, printable_limit: :infinity)}\n" <>
            script.code

        {result, _calls} = Code.evaluate(code, inner)
        # Code.evaluate/2 set its own context here.
        Process.put(Code, context)

        case result do
          %Dune.Success{value: value} -> {:ok, value, %{ran_script: name}}
          failure -> {:error, "Saved script #{name} failed: " <> failure.message}
        end
      end
    end)
  end

  defp not_nested(%{saved: outer}), do: {:error, "Saved script #{outer} can't run another."}
  defp not_nested(_context), do: :ok

  @doc """
  Searches what earlier sessions on this project said and did (their
  prompts, answers, V calls and failed scripts) for the words of `query`,
  best first: hits as `%{ref, session, at, kind, text}`. `limit:` caps
  them (10). `V.history_entry(ref)` reads a hit in full.
  """
  def history(query, opts \\ []) when is_binary(query) and is_list(opts) do
    track(:history, [query | opts_args(opts)], fn ->
      {:ok, Visor.History.search(query, Keyword.get(opts, :limit, 10))}
    end)
  end

  @doc "A `history/2` hit in full, by its ref (`\"SESSION:LINE\"`)."
  def history_entry(ref) when is_binary(ref) do
    track(:history_entry, [ref], fn -> Visor.History.entry(ref) end)
  end

  @parallel ~w(ls glob exists? read grep sh output recall job jobs history history_entry)a

  @doc """
  Runs several read-only calls at once, given as data: `V.all([{:sh,
  "mix format --check-formatted"}, {:read, ["mix.exs"]}, {:grep, ["foo",
  "lib"]}])`. Returns one result per call, in order: `{:ok, value}`, or
  `{:error, message}` for a call that failed, without stopping the others.
  Up to `Visor.Limits.parallel_calls/0` run at a time, each within the
  script's time.

  Only #{Enum.map_join(@parallel, ", ", &inspect/1)} may run this way:
  changes and checks run one at a time, so two of them never work on the
  same file at once.
  """
  def all(calls) when is_list(calls) do
    cond do
      Process.get(:visor_attempt) ->
        raise Error, "V.all can't run inside V.attempt; make its calls one after another."

      bad = Enum.find(calls, &(not parallel?(&1))) ->
        raise Error,
              "V.all runs only #{Enum.map_join(@parallel, ", ", &inspect/1)}, each as " <>
                "{name, [args]}, not #{inspect(bad)}: changes, checks and background jobs " <>
                "run one at a time."

      true ->
        :ok
    end

    track(:all, [length(calls)], fn ->
      context = Process.get(Code)
      first = Process.get(:visor_calls, 0)
      # The calls' numbers, taken now so each task reports under its own.
      Process.put(:visor_calls, first + length(calls))
      timeout = max((Code.time_left() || Limits.script_timeout_ms()) - 1_000, 0)

      results =
        calls
        |> Enum.with_index(first)
        |> Task.async_stream(
          fn {{name, args}, n} ->
            Process.put(Code, context)
            Process.put(:visor_calls, n)

            try do
              {:ok, apply(__MODULE__, name, List.wrap(args))}
            rescue
              error in Error -> {:error, error.message}
              error -> {:error, Exception.message(error)}
            end
          end,
          max_concurrency: Limits.parallel_calls(),
          timeout: timeout,
          on_timeout: :kill_task,
          ordered: true
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, :timeout} -> {:error, "stopped at the script's time limit"}
          {:exit, reason} -> {:error, Exception.format_exit(reason)}
        end)

      {:ok, results}
    end)
  end

  # A background job isn't a read, even from V.all.
  defp parallel?({:sh, [_command, opts]}) when is_list(opts),
    do: not Keyword.get(opts, :background, false)

  defp parallel?({name, args}) when name in @parallel and (is_list(args) or is_binary(args)),
    do: true

  defp parallel?(_call), do: false

  @doc """
  Runs `fun`, which changes files with `write/2` and `edit/3`, then checks
  them with `check/2` (`check:` a test path, or the whole project; and
  `timeout:` for the check). When the check passes the changes stay;
  when it fails, or `fun` raises, every file is put back as it was, and
  files it created are removed. Returns
  `%{status: :kept | :reverted, check: result, files: paths}`; a `fun`
  that raised raises again once its files are back.

  Files are put back with the same lock as any write, but another
  session that changed one of them during the attempt loses that change.
  Attempts don't nest, and a background job can't start in one.
  """
  def attempt(fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    if Process.get(:visor_attempt), do: raise(Error, "V.attempt can't run inside another.")

    case Keyword.keys(opts) -- [:check, :timeout] do
      [] -> :ok
      keys -> raise Error, "V.attempt's options are check: and timeout:, not #{inspect(keys)}."
    end

    {path, check_opts} = Keyword.pop(opts, :check)

    track(:attempt, opts_args(opts), fn ->
      Process.put(:visor_attempt, %{})

      ran =
        try do
          fun.()
          :ok
        rescue
          error -> {:error, Exception.message(error)}
        end

      originals = Process.delete(:visor_attempt) || %{}
      files = originals |> Map.keys() |> Enum.map(&Path.relative_to(&1, Workspace.root()))
      files = Enum.sort(files)

      checked =
        with :ok <- ran do
          Process.put(:visor_attempt_check, true)

          try do
            {:ok, check(path, check_opts)}
          rescue
            error in Error -> {:error, "its check failed to run: " <> error.message}
          end
        end

      case checked do
        {:ok, %{status: :ok} = check} ->
          Process.delete(:visor_attempt_check)
          {:ok, %{status: :kept, check: check, files: files}}

        {:ok, check} ->
          put_back(originals)
          forget_check()
          {:ok, %{status: :reverted, check: check, files: files}, %{reverted: files}}

        {:error, message} ->
          put_back(originals)
          forget_check()

          {:error, "V.attempt put #{Format.count(length(files), "file")} back: " <> message,
           %{reverted: files}}
      end
    end)
  end

  # The check of a tree that was put back describes nothing that exists:
  # the record it replaced comes back, so the next check compares with
  # the tree as it is.
  defp forget_check do
    case Process.delete(:visor_attempt_check) do
      {scope, previous} -> Feedback.record_check(session(), scope, previous)
      _none -> :ok
    end
  end

  defp put_back(originals) do
    root = Workspace.root()

    for {full, original} <- originals do
      path = Path.relative_to(full, root)

      change(path, fn ->
        if original == :absent, do: Tools.remove(path), else: Tools.write(path, original)
      end)
    end
  end

  @doc """
  What every compaction summary keeps, under "[Carry forward]", until it
  is removed: `V.carry(add: "the failing test is auth_test.exs:40")`,
  `V.carry(remove: "...")`, `V.carry(clear: true)`. `V.carry()` reads the
  list. Returns the list.
  """
  def carry(opts \\ []) when is_list(opts) do
    change =
      case opts do
        [] -> :read
        [add: item] when is_binary(item) -> {:add, item}
        [remove: item] when is_binary(item) -> {:remove, item}
        [clear: true] -> :clear
        _other -> :invalid
      end

    track(:carry, opts_args(opts), fn ->
      cond do
        change == :invalid ->
          {:error, ~s|V.carry takes add: "text", remove: "text" or clear: true, one at a time.|}

        session = session() ->
          Visor.Agent.carry(session, change)

        true ->
          {:error, "Carrying needs a console session."}
      end
    end)
  end

  @doc """
  Asks for the conversation to be compacted when this script's results are
  in, before the next model call: the messages before the recent part
  become a summary (see `carry/1` for what it always keeps). `reason`
  says why, for the console.
  """
  def compact(reason) when is_binary(reason) do
    track(:compact, [reason], fn ->
      case session() do
        nil -> {:error, "Compacting needs a console session."}
        session -> {:ok, Visor.Agent.request_compaction(session, reason)}
      end
    end)
  end

  @doc """
  Sets this prompt's reasoning for its next model calls: `:off` (no
  thinking), `:low`, `:high` or `:max` effort with thinking. It lasts the
  rest of the prompt, or `turns:` model calls (1 to 20); then, or when
  the user changes the setting, the user's comes back. Raise it for a
  hard step, lower it for routine ones.
  """
  def think(level, opts \\ []) when is_atom(level) and is_list(opts) do
    track(:think, [level | opts_args(opts)], fn ->
      turns =
        case Keyword.get(opts, :turns) do
          nil -> nil
          n when is_integer(n) and n in 1..20 -> n
          other -> {:invalid, other}
        end

      cond do
        Keyword.keys(opts) -- [:turns] != [] ->
          {:error, "The only option is turns: (1 to 20)."}

        match?({:invalid, _}, turns) ->
          {:error, "turns: is a whole number from 1 to 20, not #{inspect(elem(turns, 1))}."}

        session = session() ->
          with {:ok, settings} <- Visor.Agent.think(session, Atom.to_string(level), turns) do
            {:ok, Map.take(settings, [:effort, :thinking, :think])}
          end

        true ->
          {:error, "Thinking settings need a console session."}
      end
    end)
  end

  @doc """
  How full the context is: `tokens` the last request sent, the `threshold`
  that compacts it, the `window`, `share` of the threshold and `band`
  (`:ok`, `:warn` from 0.6, `:urgent` from 0.8), and what is carried.
  """
  def context do
    track(:context, [], fn ->
      case session() do
        nil -> {:error, "The context needs a console session."}
        session -> {:ok, Visor.Agent.context(session)}
      end
    end)
  end

  @doc """
  An output the script's result kept as a ref (such as `"r3"`), or only
  its lines `first..last`, counted from 1.
  """
  def output(ref, lines \\ nil) when is_binary(ref) do
    track(:output, [ref | List.wrap(lines)], fn ->
      with {:ok, text} <- kept_output(ref) do
        lines(text, lines, ref)
      end
    end)
  end

  # A job's id reads its log file: the whole of its output so far.
  defp kept_output("j" <> _ = id) do
    with {:ok, job} <- find_job(id) do
      max = Limits.read_bytes()

      case File.stat(job.log) do
        {:ok, %{size: size}} when size > max ->
          {:error,
           "#{id}'s output is #{Format.number(size)} bytes, over the " <>
             "#{Format.number(Limits.read_bytes())} V.output reads; read it in lines, " <>
             ~s|such as V.output("#{id}", 1..200).|}

        {:ok, _stat} ->
          File.read(job.log)

        {:error, _reason} ->
          {:error, "#{id}'s output is gone with its session."}
      end
    end
  end

  defp kept_output(ref), do: Feedback.fetch(session(), ref)

  @doc """
  A tool result as the model first saw it, by its tool call id: how a
  script reads back a step that a compaction summarized (see
  `Visor.Compaction`).
  """
  def recall(call_id) when is_binary(call_id),
    do: track(:recall, [call_id], fn -> Visor.Agent.recall(session(), call_id) end)

  @doc "Live statistics about the BEAM runtime."
  def beam_stats, do: track(:beam_stats, [], fn -> {:ok, Observer.beam_stats()} end)

  # Changes a file with `write` and records the change. Mix notices a
  # changed file by its size, or by its mtime, which counts whole seconds:
  # a write that leaves both as Mix last saw them (the same size, in the
  # same second) would look unchanged, so it gets an mtime a second
  # earlier. Mix only asks whether the mtime differs. All of it runs under
  # the file's lock, so another session's change waits its turn (see
  # `Visor.Lock`).
  defp change(path, write) do
    root = Workspace.root()
    full = Path.expand(path, root)

    Lock.hold({:file, full}, fn ->
      before = stat(full)
      remember_original(full)

      with :ok <- write.() do
        path = Path.relative_to(full, root)
        seen = Feedback.changed(session(), path, before)

        # A file that is gone (an attempt removing one it created) has
        # nothing to touch.
        case stat(full) do
          ^seen when seen != nil -> File.touch(full, elem(seen, 0) - 1)
          _ -> :ok
        end

        {:ok, :ok, %{changed: path}}
      end
    end)
  end

  # Inside V.attempt/2, a file's contents before its first change, or
  # :absent, so the attempt can put them back.
  defp remember_original(full) do
    with %{} = originals <- Process.get(:visor_attempt),
         false <- Map.has_key?(originals, full) do
      original =
        case File.read(full) do
          {:ok, contents} -> contents
          {:error, _reason} -> :absent
        end

      Process.put(:visor_attempt, Map.put(originals, full, original))
    end
  end

  defp stat(full) do
    case File.stat(full, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
      {:error, _reason} -> nil
    end
  end

  defp lines(text, nil, _ref), do: {:ok, text}

  defp lines(text, first..last//1, ref) when first >= 1 and last >= first do
    all = String.split(text, "\n")

    if first <= length(all),
      do: {:ok, all |> Enum.slice((first - 1)..(last - 1)//1) |> Enum.join("\n")},
      else: {:error, "#{ref} has only #{length(all)} lines."}
  end

  defp lines(_text, lines, _ref),
    do: {:error, "Lines must be a range such as 1..50, not #{inspect(lines)}."}

  # A call's time limit in ms: `opts[:timeout]` seconds or `default`,
  # ending `margin` ms before the script's own limit, so the call reports
  # its timeout before the script is stopped.
  defp within_script(opts, default, margin, allowed \\ [:timeout]) do
    asked = asked_timeout(opts, default, allowed)

    case Code.time_left() do
      nil -> asked
      left -> min(asked, max(left - margin, 0))
    end
  end

  defp asked_timeout(opts, default, allowed) do
    case Keyword.keys(opts) -- allowed do
      [] ->
        :ok

      keys when allowed == [:timeout] ->
        raise Error, "The only option is timeout: (seconds), not #{inspect(keys)}."

      keys ->
        raise Error,
              "The options are timeout: (seconds) and background: true, not #{inspect(keys)}."
    end

    case Keyword.get(opts, :timeout) do
      nil -> default
      seconds when is_number(seconds) and seconds > 0 -> round(seconds * 1000)
      other -> raise Error, "timeout: is a number of seconds, not #{inspect(other)}."
    end
  end

  defp job_session do
    case session() do
      nil -> {:error, "Background jobs need a console session."}
      session -> {:ok, session}
    end
  end

  defp with_jobs(fun) do
    with {:ok, session} <- job_session(), do: fun.(session)
  end

  defp find_job(id) do
    with {:ok, session} <- job_session() do
      case Jobs.get(session, id) do
        nil -> {:error, "There is no job #{id}."}
        job -> {:ok, job}
      end
    end
  end

  defp job_view(job) do
    job
    |> Jobs.public()
    |> Map.take([:id, :label, :status, :exit, :ms, :log, :tail])
    |> Map.update!(:ms, fn
      nil -> System.monotonic_time(:millisecond) - job.started
      ms -> ms
    end)
  end

  # Options as a call's arguments, so the console and the log show them.
  defp opts_args([]), do: []
  defp opts_args(opts), do: [opts]

  defp session do
    case Process.get(Code) do
      %{session: session} -> session
      _ -> nil
    end
  end

  # Runs a call and reports it to the console and the script's runner:
  # first as running, then finished. `fun` returns `{:ok, value}`,
  # `{:ok, value, info}` with facts for the script's result, or
  # `{:error, message}`. The reports carry the full arguments and the
  # value returned for the session log; `text` is the short form.
  defp track(name, args, fun) do
    context = Process.get(Code)
    n = Process.get(:visor_calls, 0) + 1
    # A runaway loop of calls would flood the console and the session log
    # long before the script's time limit.
    max_calls = Limits.v_calls()

    if n > max_calls do
      raise Error,
            "The script made #{Format.number(max_calls)} V calls, the most one script may make. " <>
              "Use fewer, larger calls, such as one V.grep over a folder instead of one per file."
    end

    Process.put(:visor_calls, n)

    call = %{n: n, name: name, text: call_text(name, args), args: args, status: :running, ms: nil}
    Code.report(context, call)
    started = System.monotonic_time(:millisecond)
    result = fun.()
    call = %{call | ms: System.monotonic_time(:millisecond) - started}

    case result do
      {:ok, value} ->
        Code.report(context, Map.put(%{call | status: :ok}, :returned, value))
        value

      {:ok, value, info} ->
        Code.report(context, Map.merge(%{call | status: :ok}, Map.put(info, :returned, value)))
        value

      {:error, message} ->
        Code.report(context, Map.put(%{call | status: :error}, :error, message))
        raise Error, message

      {:error, message, info} ->
        Code.report(context, Map.merge(%{call | status: :error}, Map.put(info, :error, message)))
        raise Error, message
    end
  end

  defp call_text(name, args) do
    "#{name}(" <>
      Enum.map_join(args, ", ", &inspect(&1, printable_limit: 60)) <> ")"
  end
end
