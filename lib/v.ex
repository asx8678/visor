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

  alias Visor.{Check, Code, Feedback, Format, Limits, Lock, Observer, Tools, Workspace}

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
  """
  def sh(command, opts \\ []) when is_binary(command) and is_list(opts) do
    timeout = within_script(opts, Limits.shell_timeout_ms(), 1_000)

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
        ref = if check.status != :ok, do: Feedback.keep(session, output)
        summary = Check.render(check, previous, changed, ref)
        result = Check.result(check)
        {:ok, result, %{check: summary, value: result}}
      end
    end)
  end

  @doc """
  An output the script's result kept as a ref (such as `"r3"`), or only
  its lines `first..last`, counted from 1.
  """
  def output(ref, lines \\ nil) when is_binary(ref) do
    track(:output, [ref | List.wrap(lines)], fn ->
      with {:ok, text} <- Feedback.fetch(session(), ref) do
        lines(text, lines, ref)
      end
    end)
  end

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

      with :ok <- write.() do
        path = Path.relative_to(full, root)
        seen = Feedback.changed(session(), path, before)

        case stat(full) do
          ^seen -> File.touch(full, elem(seen, 0) - 1)
          _ -> :ok
        end

        {:ok, :ok, %{changed: path}}
      end
    end)
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
  defp within_script(opts, default, margin) do
    asked =
      case Keyword.get(opts, :timeout) do
        nil ->
          default

        seconds when is_number(seconds) and seconds > 0 ->
          round(seconds * 1000)

        other ->
          raise Error, "timeout: is a number of seconds, not #{inspect(other)}."
      end

    case Keyword.keys(opts) -- [:timeout] do
      [] -> :ok
      keys -> raise Error, "The only option is timeout: (seconds), not #{inspect(keys)}."
    end

    case Code.time_left() do
      nil -> asked
      left -> min(asked, max(left - margin, 0))
    end
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
    end
  end

  defp call_text(name, args) do
    "#{name}(" <>
      Enum.map_join(args, ", ", &inspect(&1, printable_limit: 60)) <> ")"
  end
end
