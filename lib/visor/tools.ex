defmodule Visor.Tools do
  @moduledoc """
  The agent's one tool, `elixir`, and the operations its scripts call as
  functions on `V`. The model writes one script per step and the whole
  script runs in a single process (see `Visor.Code`), so a step with many
  reads, searches and commands is one model round trip.

  Every path goes through `Visor.Workspace`, which keeps it in the project
  and away from secrets. Shell commands run in the project folder but are
  not sandboxed: they don't get `DEEPSEEK_API_KEY` in their environment,
  but nothing stops one reading `.env`. Limits are in `Visor.Limits`.
  """

  alias Visor.{Format, Limits, Workspace}

  @skip_dirs ~w(.git _build deps node_modules .elixir_ls .visor)
  @skip_paths ~w(priv/static/assets)

  @doc "Tool definitions in OpenAI function format."
  def definitions do
    [
      %{
        type: "function",
        function: %{
          name: "elixir",
          description: """
          Run an Elixir script in one sandboxed BEAM process.

          Call the project through V (paths are relative to the project root):
            V.ls(path \\\\ ".")            names in a folder; folders end in /
            V.glob(pattern)               paths matching a wildcard, e.g. V.glob("lib/**/*.ex")
            V.read(path)                  a text file's contents (up to #{div(Limits.read_bytes(), 1_000_000)} MB)
            V.exists?(path)               whether a file or folder exists
            V.grep(pattern, path \\\\ ".")  matches of a regex (a string or ~r//) as
                                          %{file: path, line: n, text: line}
            V.docs("Mod.fun/2")           a module's or function's docs and signatures, from
                                          the project's compiled code (the versions it uses)
            V.source("Mod.fun")           where it is defined, %{file, line}; "dep:name" for
                                          a dependency's folder
            V.write(path, contents)       write a file, creating folders; returns :ok
            V.edit(path, old, new)        replace the one occurrence of old; returns :ok
            V.sh(command, timeout: s)     run a shell command (timeout optional, default
                                          #{div(Limits.shell_timeout_ms(), 1000)} s); returns %{status: code, output: text}
            V.check(path \\\\ nil, timeout: s, format: true)
                                          compile and run the tests (or those at a path such as
                                          "test/app_test.exs:12") in a Mix project; returns
                                          %{status: :ok | :failed | :compile_error | :timeout | :error,
                                            tests: n, failed: n, failures: [...], errors: [...]};
                                          format: true also lists files mix format would change,
                                          credo: true Credo's issues when the project has it
            V.sh(command, background: true)
                                          start a command as a background job (a long build, a
                                          server); returns %{job: id, log: path} at once. You hear
                                          when it ends, so don't poll it
            V.agent(task, seed: :snippet, role: text)
                                          start a sub-agent with a fresh context on a task, as a
                                          job; you hear its answer when it is done
            V.council(task, roles: ["security reviewer", ...])
                                          a sub-agent per role, then one that weighs their answers
            V.job(id), V.jobs()           a job's status, exit and the end of its output; all jobs
            V.stop(id), V.wait(id, timeout: s)
                                          stop a job; wait for one started earlier
            V.output(ref, first..last)    an output that was cut, kept as ref such as "r3", or a
                                          job's output by its id; all of it, or lines first..last
            V.recall(id)                  a tool result from before a compaction, by the tool
                                          call id the summary gives
            V.carry(add: text)            keep text in every compaction summary (remove: text,
                                          clear: true; V.carry() reads the list)
            V.compact(reason)             sum up what came before this prompt once it has
                                          ended, such as when a task is done
            V.context()                   %{tokens, threshold, window, share, band}: how full
                                          the context is
            V.all([{:sh, "cmd"}, {:read, ["mix.exs"]}, ...])
                                          run read-only calls (ls glob exists? read grep sh
                                          output recall job jobs) at once; returns
                                          [{:ok, value} | {:error, message}] in order
            V.attempt(fn -> edits end, check: path)
                                          make the edits, check (the tests at path, or all), and
                                          put every file back if the check fails; returns
                                          %{status: :kept | :reverted, check: result, files: [...]}
            V.save(name, code, description)
                                          keep a script to run again; V.run(name, input) runs
                                          it, with `input` bound, and returns its value;
                                          V.scripts() lists them
            V.history(query, limit: n)    what earlier sessions on this project said and did,
                                          best first; V.history_entry(ref) reads a hit in full
            V.note(text)                  a progress note for the user, under this step; you
                                          don't see it in the result
            V.think(:off | :low | :high | :max, turns: n)
                                          your reasoning for the rest of this prompt, or n calls
            V.beam_stats()                runtime statistics as a map

          The result starts with ok, or with the call that failed and its error. Then come the \
          files the script changed, the commands it ran, each check's errors and failures, what \
          it printed and its value (=> ...). Output too long to show is cut and kept as a ref.

          Kernel, Enum, String, Map, List, Keyword, Integer, Regex and Path.join/basename/dirname/\
          extname/rootname/split are available. import, alias, try/rescue, processes, File and System are not. \
          A failing V call raises and stops the script; its error comes back to you, so check \
          with V.exists? before reading a file that may be missing. A script may make up to \
          #{Format.number(Limits.v_calls())} V calls: grep a folder once rather than each file. \
          A script may be up to #{Format.number(Limits.script_chars())} characters; write a \
          longer file in parts, the first with V.write and each next one with \
          V.write(path, V.read(path) <> part). \
          A script starts with the variables the prompt's earlier scripts set, so read a file \
          into a variable once and use it in the next script; they last until the prompt ends.\
          """,
          parameters: %{
            type: "object",
            properties: %{
              code: %{type: "string", description: "The Elixir script to run."},
              timeout: %{
                type: "number",
                description:
                  "Seconds the whole script may take, when it needs more than the default " <>
                    "#{div(Limits.script_timeout_ms(), 1000)} (up to " <>
                    "#{div(Limits.max_script_timeout_ms(), 1000)}), such as for a long test suite."
              }
            },
            required: ["code"]
          }
        }
      }
    ]
  end

  @doc """
  Runs a tool with the JSON arguments string the model produced.
  Returns `{:ok, text}` or `{:error, text}`; both go back to the model.

  `context` names the session and tool call, so a script can report its
  calls to the console.
  """
  def run(name, arguments, context \\ %{}) do
    {status, text, _facts} = execute(name, arguments, context)
    {status, text}
  end

  @doc """
  Like `run/3`, and also returns what each of the script's V calls did
  (`Visor.Code.facts/1`), which the agent keeps for compaction.
  """
  def execute(name, arguments, context \\ %{})

  def execute("elixir", arguments, context) do
    decoded =
      case Jason.decode(arguments) do
        {:ok, %{} = args} -> {:ok, repair_arguments(args, context)}
        other -> other
      end

    case decoded do
      {:ok, %{"code" => code} = args} when is_binary(code) and code != "" ->
        context = Map.put(context, :timeout_ms, Visor.Code.timeout_ms(args["timeout"]))
        {status, text, calls} = Visor.Code.execute(code, context)
        {status, text, Visor.Code.facts(calls)}

      {:ok, %{}} ->
        {:error, "The elixir tool needs code, the script to run, as a non-empty string.", []}

      _ ->
        {:error, Jason.encode!(%{"INVALID_JSON" => arguments}), []}
    end
  end

  def execute(name, _arguments, _context), do: {:error, "Unknown tool #{name}. Use elixir.", []}

  @doc """
  Like `execute/3`, continuing a prompt's `Dune.Session` (see
  `Visor.Code.execute/3`): also returns the session for the next script.
  """
  def execute(name, arguments, context, %Dune.Session{} = session) do
    case {name, script_arguments(arguments, context)} do
      {"elixir", {:ok, code, args}} ->
        context = Map.put(context, :timeout_ms, Visor.Code.timeout_ms(args["timeout"]))
        {status, text, calls, session} = Visor.Code.execute(code, context, session)
        {status, text, Visor.Code.facts(calls), session}

      # Not a script to run: the same error, without telling of the
      # arguments' repairs a second time.
      _other ->
        {status, text, facts} = execute(name, arguments, Map.delete(context, :session))
        {status, text, facts, session}
    end
  end

  defp script_arguments(arguments, context) do
    with {:ok, %{} = args} <- Jason.decode(arguments),
         %{"code" => code} = args when is_binary(code) and code != "" <-
           repair_arguments(args, context) do
      {:ok, code, args}
    else
      _ -> :error
    end
  end

  @doc """
  The script an `elixir` call's `arguments` carry, as `execute/3` would
  run it after putting its shape right, trimmed; nil when there is none.
  The agent counts scripts run again unchanged by it.
  """
  def script(arguments) do
    with {:ok, %{} = args} <- Jason.decode(arguments),
         {%{"code" => code}, _fixes} when is_binary(code) <- repaired(args) do
      String.trim(code)
    else
      _ -> nil
    end
  end

  # Shapes models give the arguments that have one clear meaning, put
  # right before they are read, after pi-fabric's argument preparation:
  # the script as a list of lines, in a code fence, or under another key
  # as the only one. Each fix is a `repair` event; anything else is left
  # for the error it gets.
  defp repair_arguments(args, context) do
    {args, fixes} = repaired(args)

    if fixes != [] and context[:session] do
      Visor.Agent.Event.broadcast(
        context.session,
        {:repair,
         %{reason: :arguments, call_id: context[:call_id], fixes: fixes, answered: 0, dropped: 0}}
      )
    end

    args
  end

  defp repaired(args) do
    Enum.reduce(
      [&code_under_other_key/1, &code_as_lines/1, &code_in_fence/1],
      {args, []},
      fn fix, {args, fixes} ->
        case fix.(args) do
          {:fixed, args, what} -> {args, fixes ++ [what]}
          :ok -> {args, fixes}
        end
      end
    )
  end

  defp code_under_other_key(%{"code" => _} = _args), do: :ok

  defp code_under_other_key(args) do
    case Map.drop(args, ["timeout"]) |> Map.to_list() do
      [{key, code}] when key in ["script", "source", "elixir"] and is_binary(code) ->
        {:fixed, args |> Map.delete(key) |> Map.put("code", code), "code was under #{key}"}

      _other ->
        :ok
    end
  end

  defp code_as_lines(%{"code" => [_ | _] = lines} = args) do
    if Enum.all?(lines, &is_binary/1),
      do: {:fixed, %{args | "code" => Enum.join(lines, "\n")}, "code was a list of lines"},
      else: :ok
  end

  defp code_as_lines(_args), do: :ok

  defp code_in_fence(%{"code" => code} = args) when is_binary(code) do
    case Regex.run(~r/\A\s*```(?:elixir|ex)?[ \t]*\n(.*?)\n?```\s*\z/s, code) do
      [_, inner] -> {:fixed, %{args | "code" => inner}, "code was in a code fence"}
      nil -> :ok
    end
  end

  defp code_in_fence(_args), do: :ok

  ## Operations, called by scripts through V

  @doc "Names in a project folder, sorted; folders end in /."
  def list(path) do
    with {:ok, full} <- Workspace.resolve(path),
         {:ok, names} <- File.ls(full) |> describe_error(path) do
      {:ok,
       names
       |> Enum.sort()
       |> Enum.map(fn name ->
         if File.dir?(Path.join(full, name)), do: name <> "/", else: name
       end)}
    end
  end

  @doc "Project files matching a wildcard such as `lib/**/*.ex`, relative to the root."
  def glob(pattern) do
    root = Workspace.root()

    with {:ok, _full} <- Workspace.resolve(pattern) do
      # Braces like {..,lib} can still reach outside, so check every match.
      {:ok,
       root
       |> wildcard(Path.split(pattern))
       |> Enum.uniq()
       |> Enum.sort()
       |> Enum.map(&Path.expand/1)
       |> Enum.filter(&(Workspace.inside?(&1, root) and not Workspace.secret_file?(&1)))
       |> Enum.map(&Path.relative_to(&1, root))
       |> Enum.reject(fn path ->
         Enum.any?(Path.split(path), &(&1 in @skip_dirs or Workspace.secret?(&1)))
       end)
       |> Enum.take(Limits.glob_paths())}
    end
  end

  # Path.wildcard, except that it walks the folders a ** stands for itself:
  # Path.wildcard follows symlinked folders, and one that leads to a folder
  # above it makes the walk loop until the path is too long.
  defp wildcard(base, parts) do
    case Enum.split_while(parts, &(&1 != "**")) do
      {_no_globstar, []} ->
        Path.wildcard(Path.join([base | parts]))

      {prefix, ["**" | rest]} ->
        for dir <- Path.wildcard(Path.join([base | prefix])),
            File.dir?(dir),
            path <- below(dir, rest),
            do: path
    end
  end

  defp below(dir, []), do: tree(dir)

  defp below(dir, rest),
    do: Enum.flat_map([dir | Enum.filter(tree(dir), &folder?/1)], &wildcard(&1, rest))

  # Everything in a folder, all the way down, as ** matches it: without
  # dot names, the folders tools skip, or what symlinked folders hold.
  defp tree(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&(String.starts_with?(&1, ".") or &1 in @skip_dirs))
        |> Enum.flat_map(fn name ->
          path = Path.join(dir, name)
          if folder?(path), do: [path | tree(path)], else: [path]
        end)

      {:error, _reason} ->
        []
    end
  end

  # A folder, not a symlink to one.
  defp folder?(path), do: match?({:ok, %{type: :directory}}, File.lstat(path))

  @doc "Whether a file or folder exists in the project."
  def exists(path) do
    with {:ok, full} <- Workspace.resolve(path), do: {:ok, File.exists?(full)}
  end

  @doc "A text file's contents. Files over `max_bytes` are refused."
  def read(path, max_bytes \\ Limits.read_bytes()) do
    with {:ok, full} <- Workspace.resolve(path),
         :ok <- Workspace.readable(full, path),
         {:ok, %{size: size}} <- File.stat(full) |> describe_error(path),
         :ok <- within(size, max_bytes, path),
         {:ok, contents} <- File.read(full) |> describe_error(path) do
      if String.valid?(contents),
        do: {:ok, contents},
        else: {:error, "#{path} is not a text file."}
    end
  end

  @doc "Lines matching a regular expression, as maps with `:file`, `:line` and `:text`."
  def search(pattern, path, max_matches \\ Limits.grep_matches()) do
    with {:ok, full} <- Workspace.resolve(path),
         # A folder's secrets are skipped as it is walked; this is for one named.
         :ok <- Workspace.readable(full, path),
         {:ok, regex} <- compile(pattern) do
      root = Workspace.root()

      {:ok,
       full
       |> files(root)
       |> Stream.flat_map(&matching_lines(&1, regex, root))
       |> Enum.take(max_matches)}
    end
  end

  @doc "Writes a project file, creating its folder if needed."
  def write(path, contents) do
    with {:ok, full} <- Workspace.resolve(path),
         :ok <- Workspace.writable(full, path),
         :ok <- File.mkdir_p(Path.dirname(full)) |> describe_error(path, "write"),
         :ok <- File.write(full, contents) |> describe_error(path, "write") do
      :ok
    end
  end

  @doc "Removes a project file, as undoing a write that created it (`V.attempt/2`)."
  def remove(path) do
    with {:ok, full} <- Workspace.resolve(path),
         :ok <- Workspace.writable(full, path) do
      case File.rm(full) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        error -> describe_error(error, path, "remove")
      end
    end
  end

  @doc "Replaces the one occurrence of `old` in a project file with `new`."
  def edit(_path, "", _new), do: {:error, "The text to replace can't be empty."}

  def edit(path, old, new) do
    with {:ok, contents} <- read(path) do
      case :binary.matches(contents, old) do
        [_one] ->
          write(path, String.replace(contents, old, new))

        [] ->
          {:error, "The text to replace was not found in #{path}."}

        matches ->
          {:error,
           "The text to replace appears #{length(matches)} times in #{path}. " <>
             "Include more of the surrounding text so it appears once."}
      end
    end
  end

  # Kills every process whose VISOR_RUN tag is this command's or nests
  # under it, except the shell running this. A process that leaves the
  # command's process group, with setsid or as a child BEAM's port, keeps
  # its environment and so its tag. Linux only (/proc); elsewhere nothing
  # matches and the process group kill still applies.
  @kill_tagged ~S"""
  read -r self _ < /proc/self/stat 2>/dev/null; tag=${VISOR_RUN##*:}
  for p in $(grep -lsz "^VISOR_RUN=.*:$tag\(:.*\)\{0,1\}$" /proc/[0-9]*/environ | cut -d/ -f3); do
    [ "$p" = "$self" ] || kill -KILL "$p" 2>/dev/null
  done
  """

  # Runs before each command. A background `cat` holds the port's stdin,
  # which closes when the command ends, its caller dies or the VM exits,
  # and then kills what carries the command's tag and its process group.
  # The command itself reads from /dev/null.
  @watchdog """
  exec 3<&0
  (cat <&3 >/dev/null 2>&1; #{@kill_tagged}kill -KILL 0) >/dev/null 2>&1 &
  exec 3<&- </dev/null
  """

  @doc """
  Runs a shell command in the project folder. Returns `{status, output}`,
  where status is the exit code, or `:timeout` if it was killed at its
  timeout (`Visor.Limits.shell_timeout_ms/0` by default). Whatever the
  command started is stopped with it, background jobs included.

  Options: `:timeout` in milliseconds, `:max_bytes` of output to keep
  (`Visor.Limits.result_bytes/0` by default), `:env`, extra environment
  variables as `{name, value}` strings, and for a background job (see
  `Visor.Jobs`) `:on_start`, called with the command's OS pid, and
  `:on_data`, called with each piece of output as it comes.

  The calling process owns the command: when it exits, the command and
  everything it started are killed.
  """
  def shell(command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Limits.shell_timeout_ms())
    extra_env = for {name, value} <- Keyword.get(opts, :env, []), do: {~c"#{name}", ~c"#{value}"}
    # Unique to this command and this VM. A command run by a Visor that is
    # itself under a command (its tests, say) adds to the tag it inherited,
    # so the outer command's kill reaches it too.
    tag = "#{System.get_env("VISOR_RUN")}:#{System.pid()}-#{System.unique_integer([:positive])}"

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", @watchdog <> command],
        cd: Workspace.root(),
        env: [
          # Unset, so the key can't be read back with `env`.
          {~c"DEEPSEEK_API_KEY", false},
          {~c"PAGER", ~c"cat"},
          {~c"GIT_PAGER", ~c"cat"},
          {~c"TERM", ~c"dumb"},
          {~c"VISOR_RUN", String.to_charlist(tag)} | extra_env
        ]
      ])

    # nil when a quick command has already exited, and closed its port;
    # its output and exit status are waiting in the mailbox.
    os_pid = with {:os_pid, os_pid} <- Port.info(port, :os_pid), do: os_pid
    if on_start = opts[:on_start], do: on_start.(os_pid)
    limit = Keyword.get(opts, :max_bytes, Limits.result_bytes())
    deadline = System.monotonic_time(:millisecond) + timeout
    on_data = Keyword.get(opts, :on_data, fn _data -> :ok end)
    run = %{os_pid: os_pid, tag: tag, deadline: deadline, limit: limit, on_data: on_data}
    shell_output(port, run, [], 0)
  end

  # What carries the command's tag, then its process group. The port's
  # process leads a process group of its own (erl_child_setup starts each
  # in a new session), so killing the group also stops what the command
  # started, such as the mix test under a `mix test` shell.
  defp kill(%{os_pid: os_pid, tag: tag}) do
    System.cmd("sh", ["-c", @kill_tagged], env: [{"VISOR_RUN", tag}], stderr_to_stdout: true)
    if os_pid, do: System.cmd("kill", ["-KILL", "--", "-#{os_pid}"], stderr_to_stdout: true)
  end

  @doc "Cuts text for a tool result to `Visor.Limits.result_bytes/0`."
  def clip(text) do
    limit = Limits.result_bytes()

    if byte_size(text) > limit,
      do: truncate(text, limit) <> "\n[output truncated at #{div(limit, 1000)} KB]",
      else: text
  end

  # Collects output until the command exits, keeping the first `limit` bytes.
  defp shell_output(port, run, acc, size) do
    receive do
      {^port, {:data, data}} when size < run.limit ->
        run.on_data.(data)
        shell_output(port, run, [acc | data], size + byte_size(data))

      {^port, {:data, data}} ->
        run.on_data.(data)
        shell_output(port, run, acc, size)

      {^port, {:exit_status, status}} ->
        {status, shell_text(acc, size, run.limit)}
    after
      max(run.deadline - System.monotonic_time(:millisecond), 0) ->
        kill(run)
        {:timeout, shell_text(acc, size, run.limit)}
    end
  end

  defp shell_text(acc, size, limit) do
    output = acc |> IO.iodata_to_binary() |> truncate(limit)

    cond do
      size > limit -> output <> "\n[output truncated at #{div(limit, 1000)} KB]"
      output == "" -> "(no output)"
      true -> output
    end
  end

  @doc """
  Cuts text to a byte limit without leaving a broken UTF-8 sequence, which
  would make the next request body fail to encode.
  """
  def truncate(text, bytes) do
    text
    |> binary_part(0, min(bytes, byte_size(text)))
    |> String.replace_invalid()
  end

  defp within(size, max_bytes, _path) when size <= max_bytes, do: :ok

  defp within(_size, max_bytes, path),
    do: {:error, "#{path} is over #{div(max_bytes, 1_000_000)} MB."}

  defp describe_error(result, path, verb \\ "read")
  defp describe_error(:ok, _path, _verb), do: :ok
  defp describe_error({:ok, value}, _path, _verb), do: {:ok, value}
  defp describe_error({:error, :enoent}, path, _verb), do: {:error, "#{path} does not exist."}
  defp describe_error({:error, :enotdir}, path, _verb), do: {:error, "#{path} is not a folder."}

  defp describe_error({:error, :eisdir}, path, _verb),
    do: {:error, "#{path} is a folder, not a file."}

  defp describe_error({:error, reason}, path, verb),
    do: {:error, "Could not #{verb} #{path}: #{reason}."}

  defp compile(%Regex{} = regex), do: {:ok, regex}

  defp compile(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, _} -> {:ok, Regex.compile!(Regex.escape(pattern))}
    end
  end

  defp files(path, root) do
    cond do
      File.regular?(path) ->
        [path]

      Path.relative_to(path, root) in @skip_paths ->
        []

      File.dir?(path) ->
        case File.ls(path) do
          {:ok, names} ->
            names
            |> Enum.sort()
            |> Enum.reject(&(&1 in @skip_dirs or Workspace.secret?(&1)))
            |> Enum.map(&Path.join(path, &1))
            |> Enum.filter(&searchable?(&1, root))
            |> Stream.flat_map(&files(&1, root))

          {:error, _} ->
            []
        end

      true ->
        []
    end
  end

  # Symlinked folders aren't searched, since one can lead back up and
  # loop. A symlinked file is, if it leads to a file in the project that
  # isn't a secret. Anything else was checked with its folder.
  defp searchable?(path, root) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        File.regular?(path) and Workspace.real_under?(path, root) and
          not Workspace.secret_file?(path)

      _other ->
        true
    end
  end

  defp matching_lines(file, regex, root) do
    max_bytes = Limits.grep_file_bytes()

    with {:ok, %{size: size}} when size < max_bytes <- File.stat(file),
         {:ok, contents} <- File.read(file),
         true <- String.valid?(contents) do
      relative = Path.relative_to(file, root)

      contents
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
      |> Enum.map(fn {line, n} ->
        %{file: relative, line: n, text: String.slice(String.trim(line), 0, 200)}
      end)
    else
      _ -> []
    end
  end
end
