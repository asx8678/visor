defmodule Visor.Tools do
  @moduledoc """
  Tools the agent can call. File paths are confined to the workspace (the
  project folder by default); `bash` runs there but is not sandboxed.
  Every call runs in its own supervised task.

  The `elixir` tool is code mode: the model writes one script that calls
  these operations as functions on `V`, and the whole script runs in a
  single process (see `Visor.Code`).
  """

  @max_file_bytes 64_000
  @max_read_bytes 10_000_000
  @max_output_bytes 32_000
  @bash_timeout_ms 60_000
  @max_entries 300
  @max_matches 80
  @max_glob 2_000
  @skip_dirs ~w(.git _build deps node_modules .elixir_ls)
  @skip_paths ~w(priv/static/assets)

  @doc "The folder tools may read from."
  def workspace, do: Application.get_env(:visor, :workspace) || File.cwd!()

  @doc "Tool definitions in OpenAI function format."
  def definitions do
    [
      function(
        "elixir",
        """
        Run an Elixir script in one sandboxed BEAM process. Prefer this tool: do all the reads, \
        searches, edits and commands a step needs in one script, and return only what you need \
        to see.

        Call the project through V (paths are relative to the project root):
          V.ls(path \\\\ ".")            names in a folder; folders end in /
          V.glob(pattern)               paths matching a wildcard, e.g. V.glob("lib/**/*.ex")
          V.read(path)                  a text file's contents (up to 2 MB)
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
        2,000 V calls: grep a folder once rather than each file.\
        """,
        %{code: %{type: "string", description: "The Elixir script to run."}},
        ["code"]
      ),
      function(
        "list_dir",
        "List the files and folders at a path in the project. Call this to explore the codebase before reading files.",
        %{
          path: %{
            type: "string",
            description: "Path relative to the project root. Defaults to \".\"."
          }
        },
        []
      ),
      function(
        "read_file",
        "Read a text file in the project (up to 64 KB). Call this when you need a file's contents.",
        %{path: %{type: "string", description: "Path relative to the project root."}},
        ["path"]
      ),
      function(
        "grep",
        "Search text files in the project for a regular expression and return matching lines with file and line number. Call this to find where something is defined or used.",
        %{
          pattern: %{type: "string", description: "Regular expression to search for."},
          path: %{
            type: "string",
            description: "Folder to search, relative to the project root. Defaults to \".\"."
          }
        },
        ["pattern"]
      ),
      function(
        "bash",
        "Run a shell command with /bin/sh in the project folder and return its combined stdout and stderr (up to 32 KB). " <>
          "The command gets no stdin and is killed after 60 seconds. Use it for what the other tools can't do, such as running mix tasks.",
        %{command: %{type: "string", description: "The command to run."}},
        ["command"]
      ),
      function(
        "beam_stats",
        "Report live statistics about the BEAM runtime this agent runs in: process count, memory, schedulers and the busiest processes. Call this when the user asks about the runtime, processes, memory or load.",
        %{},
        []
      )
    ]
  end

  defp function(name, description, properties, required) do
    %{
      type: "function",
      function: %{
        name: name,
        description: description,
        parameters: %{type: "object", properties: properties, required: required}
      }
    }
  end

  @doc """
  Runs a tool with the JSON arguments string the model produced.
  Returns `{:ok, text}` or `{:error, text}`; both go back to the model.

  `context` names the session and tool call, so an `elixir` script can
  report its calls to the console.
  """
  def run(name, arguments, context \\ %{}) do
    with {:ok, args} <- decode(arguments) do
      call(name, args, context)
    end
  end

  defp decode(""), do: {:ok, %{}}

  defp decode(arguments) do
    case Jason.decode(arguments) do
      {:ok, args} when is_map(args) -> {:ok, args}
      _ -> {:error, Jason.encode!(%{"INVALID_JSON" => arguments})}
    end
  end

  defp call("elixir", args, context) do
    with {:ok, code} <- string_arg(args, "code", nil) do
      Visor.Code.run(code, context)
    end
  end

  defp call(name, args, _context), do: call(name, args)

  defp call("list_dir", args) do
    with {:ok, path} <- string_arg(args, "path", "."),
         {:ok, names} <- list(path) do
      entries = names |> Enum.take(@max_entries) |> Enum.join("\n")
      {:ok, if(entries == "", do: "(empty folder)", else: entries)}
    end
  end

  defp call("read_file", args) do
    with {:ok, path} <- string_arg(args, "path", nil),
         {:ok, contents} <- read(path, @max_read_bytes) do
      if byte_size(contents) > @max_file_bytes,
        do: {:ok, truncate(contents, @max_file_bytes) <> "\n[truncated at 64 KB]"},
        else: {:ok, contents}
    end
  end

  defp call("grep", args) do
    with {:ok, pattern} <- string_arg(args, "pattern", nil),
         {:ok, path} <- string_arg(args, "path", "."),
         {:ok, matches} <- search(pattern, path, @max_matches) do
      case matches do
        [] -> {:ok, "No matches for #{pattern}."}
        matches -> {:ok, Enum.map_join(matches, "\n", &"#{&1.file}:#{&1.line}: #{&1.text}")}
      end
    end
  end

  defp call("bash", args) do
    with {:ok, command} <- string_arg(args, "command", nil) do
      case shell(command) do
        {0, output} ->
          {:ok, output}

        {:timeout, output} ->
          {:error, output <> "\n[killed after #{div(@bash_timeout_ms, 1000)} s]"}

        {status, output} ->
          {:error, output <> "\n[exit status #{status}]"}
      end
    end
  end

  defp call("beam_stats", _args) do
    stats = stats()

    busiest =
      Enum.map_join(stats.busiest, "\n", fn process ->
        "  #{process.name} #{process.pid}: #{process.reductions} reductions, " <>
          "#{process.memory_kb} KB, #{process.queue} queued"
      end)

    {:ok,
     """
     Processes: #{stats.processes} of #{stats.process_limit}
     Memory: #{stats.memory_mb} MB total, #{stats.process_memory_mb} MB in processes
     Schedulers online: #{stats.schedulers}
     Run queue: #{stats.run_queue}
     Uptime: #{stats.uptime_s} s
     OTP #{stats.otp}, Elixir #{stats.elixir}
     Busiest processes by reductions:
     #{busiest}\
     """}
  end

  defp call(name, _args), do: {:error, "Unknown tool #{name}."}

  ## Operations, shared by the tools above and by code mode (V)

  @doc "Names in a project folder, sorted; folders end in /."
  def list(path) do
    with {:ok, full} <- resolve(path),
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
    root = workspace()

    with {:ok, _full} <- resolve(pattern) do
      # Braces like {..,lib} can still reach outside, so check every match.
      {:ok,
       root
       |> wildcard(Path.split(pattern))
       |> Enum.uniq()
       |> Enum.sort()
       |> Enum.map(&Path.expand/1)
       |> Enum.filter(&(inside?(&1, root) and not secret_file?(&1)))
       |> Enum.map(&Path.relative_to(&1, root))
       |> Enum.reject(fn path ->
         Enum.any?(Path.split(path), &(&1 in @skip_dirs or secret?(&1)))
       end)
       |> Enum.take(@max_glob)}
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
    with {:ok, full} <- resolve(path), do: {:ok, File.exists?(full)}
  end

  @doc "A text file's contents. Files over `max_bytes` are refused."
  def read(path, max_bytes) do
    with {:ok, full} <- resolve(path),
         :ok <- readable(full, path),
         {:ok, %{size: size}} <- File.stat(full) |> describe_error(path),
         :ok <- within(size, max_bytes, path),
         {:ok, contents} <- File.read(full) |> describe_error(path) do
      if String.valid?(contents),
        do: {:ok, contents},
        else: {:error, "#{path} is not a text file."}
    end
  end

  @doc "Lines matching a regular expression, as maps with `:file`, `:line` and `:text`."
  def search(pattern, path, max_matches) do
    with {:ok, full} <- resolve(path),
         {:ok, regex} <- compile(pattern) do
      root = workspace()

      {:ok,
       full
       |> files(root)
       |> Stream.flat_map(&matching_lines(&1, regex, root))
       |> Enum.take(max_matches)}
    end
  end

  @doc "Writes a project file, creating its folder if needed."
  def write(path, contents) do
    with {:ok, full} <- resolve(path),
         :ok <- writable(full, path),
         :ok <- File.mkdir_p(Path.dirname(full)) |> describe_error(path, "write"),
         :ok <- File.write(full, contents) |> describe_error(path, "write") do
      :ok
    end
  end

  @doc "Replaces the one occurrence of `old` in a project file with `new`."
  def edit(_path, "", _new), do: {:error, "The text to replace can't be empty."}

  def edit(path, old, new) do
    with {:ok, contents} <- read(path, @max_read_bytes) do
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
  timeout (60 seconds by default).

  Options: `:timeout` in milliseconds, `:max_bytes` of output to keep
  (32 KB by default), and `:env`, extra environment variables as
  `{name, value}` strings.
  """
  def shell(command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @bash_timeout_ms)
    extra_env = for {name, value} <- Keyword.get(opts, :env, []), do: {~c"#{name}", ~c"#{value}"}

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", "exec </dev/null\n" <> command],
        cd: workspace(),
        env: [{~c"PAGER", ~c"cat"}, {~c"GIT_PAGER", ~c"cat"}, {~c"TERM", ~c"dumb"} | extra_env]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    limit = Keyword.get(opts, :max_bytes, @max_output_bytes)
    deadline = System.monotonic_time(:millisecond) + timeout
    shell_output(port, %{os_pid: os_pid, deadline: deadline, limit: limit}, [], 0)
  end

  @doc "Live statistics about the BEAM runtime."
  def stats do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    busiest =
      Process.list()
      |> Enum.flat_map(fn pid ->
        case Process.info(pid, [:reductions, :memory, :message_queue_len]) do
          nil -> []
          info -> [{pid, info}]
        end
      end)
      |> Enum.sort_by(fn {_pid, info} -> -info[:reductions] end)
      |> Enum.take(8)
      |> Enum.map(fn {pid, info} ->
        %{
          name: Visor.Observer.describe(pid),
          pid: inspect(pid),
          reductions: info[:reductions],
          memory_kb: div(info[:memory], 1024),
          queue: info[:message_queue_len]
        }
      end)

    %{
      processes: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      memory_mb: mb(:erlang.memory(:total)),
      process_memory_mb: mb(:erlang.memory(:processes)),
      schedulers: :erlang.system_info(:schedulers_online),
      run_queue: :erlang.statistics(:total_run_queue_lengths),
      uptime_s: div(uptime_ms, 1000),
      otp: List.to_string(:erlang.system_info(:otp_release)),
      elixir: System.version(),
      busiest: busiest
    }
  end

  @doc "Cuts text for a tool result to 32 KB."
  def clip(text) do
    if byte_size(text) > @max_output_bytes,
      do: truncate(text, @max_output_bytes) <> "\n[output truncated at 32 KB]",
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
        System.cmd("kill", ["-KILL", Integer.to_string(run.os_pid)], stderr_to_stdout: true)
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

  defp string_arg(args, key, default) do
    case Map.get(args, key, default) do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:error, "Missing required argument #{key}."}
      _ -> {:error, "Argument #{key} must be a non-empty string."}
    end
  end

  defp resolve(path) do
    root = workspace()
    full = Path.expand(path, root)

    if inside?(full, root),
      do: {:ok, full},
      else: {:error, "#{path} is outside the project folder."}
  end

  # Whether a path is in the project both as written and once each symlink
  # in it is followed, so a link can't lead outside.
  defp inside?(full, root), do: under?(full, root) and real_under?(full, root)

  defp real_under?(full, root) do
    case {real(root), real(full)} do
      {{:ok, real_root}, {:ok, real}} -> under?(real, real_root)
      _loop -> false
    end
  end

  defp under?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  @max_links 40

  # The path the OS opens for `full`: each symlink in it followed, as far
  # as it exists. `:loop` for a link that leads back to itself.
  defp real(full) do
    [top | parts] = Path.split(full)
    follow(parts, top, 0)
  end

  defp follow(_parts, _path, links) when links > @max_links, do: :loop
  defp follow([], path, _links), do: {:ok, path}
  defp follow(["." | parts], path, links), do: follow(parts, path, links)
  defp follow([".." | parts], path, links), do: follow(parts, Path.dirname(path), links)

  defp follow([part | parts], path, links) do
    next = Path.join(path, part)

    case File.read_link(next) do
      # A relative target starts from the link's folder.
      {:ok, target} ->
        case Path.split(target) do
          ["/" | target] -> follow(target ++ parts, "/", links + 1)
          target -> follow(target ++ parts, path, links + 1)
        end

      {:error, _not_a_link} ->
        follow(parts, next, links)
    end
  end

  # .env holds the API key; keep it out of tool results (and so out of the
  # transcript and the request body), under its own name or a link's.
  defp readable(full, path) do
    if secret_file?(full),
      do: {:error, "#{path} holds secrets and can't be read."},
      else: :ok
  end

  defp writable(full, path) do
    if secret_file?(full),
      do: {:error, "#{path} holds secrets and can't be changed."},
      else: :ok
  end

  defp secret_file?(full) do
    case real(full) do
      {:ok, real} -> secret?(Path.basename(full)) or secret?(Path.basename(real))
      :loop -> secret?(Path.basename(full))
    end
  end

  defp secret?(name), do: name == ".env" or String.starts_with?(name, ".env.")

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
            |> Enum.reject(&(&1 in @skip_dirs or secret?(&1)))
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
        File.regular?(path) and real_under?(path, root) and not secret_file?(path)

      _other ->
        true
    end
  end

  defp matching_lines(file, regex, root) do
    with {:ok, %{size: size}} when size < 1_000_000 <- File.stat(file),
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

  defp mb(bytes), do: Float.round(bytes / 1_048_576, 1)
end
