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

  @skip_dirs ~w(.git _build deps node_modules .elixir_ls)
  @skip_paths ~w(priv/static/assets)

  @doc "Tool definitions in OpenAI function format."
  def definitions do
    [
      %{
        type: "function",
        function: %{
          name: "elixir",
          description: """
          Run an Elixir script in one sandboxed BEAM process. Do all the reads, searches, edits \
          and commands a step needs in one script, and return only what you need to see.

          Call the project through V (paths are relative to the project root):
            V.ls(path \\\\ ".")            names in a folder; folders end in /
            V.glob(pattern)               paths matching a wildcard, e.g. V.glob("lib/**/*.ex")
            V.read(path)                  a text file's contents (up to #{div(Limits.read_bytes(), 1_000_000)} MB)
            V.exists?(path)               whether a file or folder exists
            V.grep(pattern, path \\\\ ".")  matches of a regex (a string or ~r//) as
                                          %{file: path, line: n, text: line}
            V.write(path, contents)       write a file, creating folders; returns :ok
            V.edit(path, old, new)        replace the one occurrence of old; returns :ok
            V.sh(command)                 run a shell command; returns %{status: code, output: text}
            V.check(path \\\\ nil)          compile and run the tests (or those at a path such as
                                          "test/app_test.exs:12") in a Mix project; returns
                                          %{status: :ok | :failed | :compile_error, failures: [...]}
            V.output(ref, first..last)    an output that was cut, kept as ref such as "r3";
                                          all of it, or only its lines first..last
            V.beam_stats()                runtime statistics as a map

          The result starts with ok, or with the call that failed and its error. Then come the \
          files the script changed, the commands it ran, each check's errors and failures, what \
          it printed and its value (=> ...). Output too long to show is cut and kept as a ref.

          Kernel, Enum, String, Map, List, Keyword, Integer, Regex and Path.join/basename/dirname/\
          extname are available. import, alias, try/rescue, processes, File and System are not. \
          A failing V call raises and stops the script; its error comes back to you, so check \
          with V.exists? before reading a file that may be missing. A script may make up to \
          #{Format.number(Limits.v_calls())} V calls: grep a folder once rather than each file. \
          A script may be up to #{Format.number(Limits.script_chars())} characters; write a \
          longer file in parts, the first with V.write and each next one with \
          V.write(path, V.read(path) <> part).\
          """,
          parameters: %{
            type: "object",
            properties: %{code: %{type: "string", description: "The Elixir script to run."}},
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
  def run(name, arguments, context \\ %{})

  def run("elixir", arguments, context) do
    case Jason.decode(arguments) do
      {:ok, %{"code" => code}} when is_binary(code) and code != "" ->
        Visor.Code.run(code, context)

      {:ok, %{}} ->
        {:error, "The elixir tool needs code, the script to run, as a non-empty string."}

      _ ->
        {:error, Jason.encode!(%{"INVALID_JSON" => arguments})}
    end
  end

  def run(name, _arguments, _context), do: {:error, "Unknown tool #{name}. Use elixir."}

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

  @doc """
  Runs a shell command in the project folder. Returns `{status, output}`,
  where status is the exit code, or `:timeout` if it was killed at its
  timeout (`Visor.Limits.shell_timeout_ms/0` by default).

  Options: `:timeout` in milliseconds, `:max_bytes` of output to keep
  (`Visor.Limits.result_bytes/0` by default), and `:env`, extra
  environment variables as `{name, value}` strings.
  """
  def shell(command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Limits.shell_timeout_ms())
    extra_env = for {name, value} <- Keyword.get(opts, :env, []), do: {~c"#{name}", ~c"#{value}"}

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", "exec </dev/null\n" <> command],
        cd: Workspace.root(),
        env: [
          # Unset, so the key can't be read back with `env`.
          {~c"DEEPSEEK_API_KEY", false},
          {~c"PAGER", ~c"cat"},
          {~c"GIT_PAGER", ~c"cat"},
          {~c"TERM", ~c"dumb"} | extra_env
        ]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    watcher = kill_when_down(self(), os_pid)
    limit = Keyword.get(opts, :max_bytes, Limits.result_bytes())
    deadline = System.monotonic_time(:millisecond) + timeout
    result = shell_output(port, %{os_pid: os_pid, deadline: deadline, limit: limit}, [], 0)
    send(watcher, :done)
    result
  end

  # The port's process leads a process group of its own (erl_child_setup
  # starts each in a new session), so killing the group also stops what
  # the command started, such as the mix test under a `mix test` shell.
  defp kill_group(os_pid) do
    System.cmd("kill", ["-KILL", "--", "-#{os_pid}"], stderr_to_stdout: true)
  end

  # Kills the command's group if `owner` dies before it finishes: a script
  # stopped at its time limit, or a tool the user cancelled. Closing the
  # port alone leaves the command running.
  defp kill_when_down(owner, os_pid) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        :done -> :ok
        {:DOWN, ^ref, :process, _pid, _reason} -> kill_group(os_pid)
      end
    end)
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
        shell_output(port, run, [acc | data], size + byte_size(data))

      {^port, {:data, _data}} ->
        shell_output(port, run, acc, size)

      {^port, {:exit_status, status}} ->
        {status, shell_text(acc, size, run.limit)}
    after
      max(run.deadline - System.monotonic_time(:millisecond), 0) ->
        kill_group(run.os_pid)
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
