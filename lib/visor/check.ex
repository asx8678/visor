defmodule Visor.Check do
  @moduledoc """
  `V.check/1`: compiles the project and runs its tests in one `mix test`,
  then reads the result out of mix's output.

  The summary is deterministic. The tests run with `--seed 0`, and the
  summary leaves out timings, seeds and progress dots and sorts what it
  lists, so the same code always gives the same text. It also says what
  changed since the last check of the same tests:

      check failed: 1 of 31 tests
      since the last check: 2 fixed, 0 new, 1 still failing
      fixed: "edits files" (Visor.CodeTest), "reads files" (Visor.CodeTest)
      failures:
        test/visor/code_test.exs:40 "stops on first failure" (Visor.CodeTest)
          Assertion with =~ failed
          left:  "Cancelled."
          right: "not found"
          at test/visor/code_test.exs:41: (test)
      full output: r4
  """

  alias Visor.{Format, Lock, Tools, Workspace}

  @max_output_bytes 4_000_000
  @shown_failures 8
  @shown_message_lines 8
  @shown_names 5
  @shown_diagnostics 10
  @shown_tail 5
  @line_chars 160
  # ExUnit indents everything under a failure's head by five spaces.
  @body_indent 5
  # Stack frames from these say where Elixir noticed, not what went wrong.
  @runtime_apps ~w(elixir stdlib kernel ex_unit mix iex logger eex compiler erts)

  defstruct status: :ok,
            exit: 0,
            tests: 0,
            passed: 0,
            failed: 0,
            skipped: 0,
            excluded: 0,
            invalid: 0,
            failures: [],
            diagnostics: [],
            aborted: nil,
            tail: [],
            # The time limit it ran under.
            limit_ms: nil

  @test_head ~r/^\s*\d+\) (test|doctest) (.+) \(([\w.]+)\)$/
  @module_head ~r/^\s*\d+\) ([\w.]+): (failure on .+)$/
  @location ~r/^\s+(\S+):(\d+)$/
  @diagnostic ~r/^\s*(warning|error): (.+)$/
  @diagnostic_at ~r/└─ ([^\s:]+):(\d+)/
  @frame_app ~r/^\((\w+) [\w.+-]+\) /
  @progress ~r/^(Compiling \d+ files? |Generated \w+ app|Running ExUnit |Finished in )/

  @doc """
  Runs `mix test` in the project, or only the tests at `path`. Returns
  `{:ok, check, output}` or `{:error, message}`.

  Checks of one project run one at a time, across sessions (see
  `Visor.Lock`). The time a check waits for another comes out of its
  time limit, so it still ends before the script's.
  """
  def run(path \\ nil, timeout \\ Visor.Limits.check_timeout_ms()) do
    with :ok <- mix_project(),
         {:ok, args} <- path_args(path) do
      asked = System.monotonic_time(:millisecond)

      {exit, output} =
        Lock.hold({:check, Path.expand(Workspace.root())}, fn ->
          waited = System.monotonic_time(:millisecond) - asked

          Tools.shell(Enum.join(["mix test --seed 0" | args], " "),
            timeout: max(timeout - waited, 0),
            max_bytes: @max_output_bytes,
            env: [{"MIX_ENV", "test"}]
          )
        end)

      {:ok, %{parse(output, exit) | limit_ms: timeout}, output}
    end
  end

  defp mix_project do
    if File.regular?(Path.join(Workspace.root(), "mix.exs")),
      do: :ok,
      else: {:error, "V.check needs a Mix project, and the project folder has no mix.exs."}
  end

  defp path_args(nil), do: {:ok, []}

  defp path_args(path) do
    if path =~ ~r/\A[\w.-][\w.\/-]*(:\d+)?\z/ and not String.contains?(path, "..") do
      {:ok, [path]}
    else
      {:error,
       "V.check takes a test path such as \"test/app_test.exs\" or " <>
         "\"test/app_test.exs:12\", not #{inspect(path)}."}
    end
  end

  @doc "Reads the output and exit status of `mix test` into a check."
  def parse(output, exit) do
    lines = String.split(output, "\n")
    failures = failures(lines)
    diagnostics = diagnostics(lines)
    aborted = aborted(lines)
    counts = counts(lines)

    status =
      cond do
        exit == :timeout ->
          :timeout

        aborted != nil ->
          :compile_error

        counts == %{} and Enum.any?(diagnostics, &(&1.severity == :error)) ->
          :compile_error

        exit == 0 ->
          :ok

        failures != [] or Map.get(counts, :failed, 0) > 0 or Map.get(counts, :invalid, 0) > 0 ->
          :failed

        true ->
          :error
      end

    struct!(
      %__MODULE__{
        status: status,
        exit: exit,
        failures: failures,
        diagnostics: diagnostics,
        aborted: aborted,
        tail: if(status == :error, do: tail(lines), else: [])
      },
      Map.put_new(counts, :failed, Enum.count(failures, &(&1.kind != "module")))
    )
  end

  @doc "What `V.check/1` returns to the script."
  def result(check) do
    %{
      status: check.status,
      tests: check.tests,
      failed: check.failed,
      failures:
        Enum.map(
          check.failures,
          &%{test: &1.name, module: &1.module, file: &1.file, line: &1.line}
        ),
      errors:
        for(
          d <- check.diagnostics,
          d.severity == :error,
          do: Map.take(d, [:file, :line, :message])
        )
    }
  end

  @doc """
  The check as the model sees it. `previous` is the last check of the same
  tests; `changed` lists the files the session changed, whose warnings are
  shown while the rest are only counted; `ref` names the full output.
  """
  def render(check, previous \\ nil, changed \\ [], ref \\ nil) do
    before = if comparable?(check, previous), do: failing(previous)

    [
      headline(check),
      if(before, do: comparison(before, failing(check))),
      failure_lines(check, before),
      error_lines(check),
      tail_lines(check),
      warning_lines(check, changed),
      if(ref, do: "full output: #{ref}")
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  ## Reading mix's output

  # A failure is its head line and the lines indented under it, up to the
  # next line indented less (progress dots, "Finished in", the result).
  defp failures(lines) do
    lines
    |> Enum.reduce([], fn line, chunks ->
      cond do
        head?(line) -> [[line] | chunks]
        chunks == [] or match?([:done | _], chunks) -> chunks
        String.trim(line) == "" -> chunks
        leading_spaces(line) < @body_indent -> [:done | chunks]
        true -> List.update_at(chunks, 0, &[line | &1])
      end
    end)
    |> Enum.reject(&(&1 == :done))
    |> Enum.map(&failure(Enum.reverse(&1)))
    |> Enum.sort_by(&{&1.file || "", &1.line || 0, &1.module, &1.name})
  end

  defp head?(line), do: Regex.match?(@test_head, line) or Regex.match?(@module_head, line)

  defp failure([head | body]) do
    base =
      case Regex.run(@test_head, head) do
        [_, kind, name, module] ->
          %{kind: kind, name: name, module: module}

        nil ->
          [_, module, what] = Regex.run(@module_head, head)
          %{kind: "module", name: what, module: module}
      end

    {location, rest} =
      with [first | rest] <- body,
           [_, file, line] <- Regex.run(@location, first) do
        {%{file: file, line: String.to_integer(line)}, rest}
      else
        _ -> {%{file: nil, line: nil}, body}
      end

    {message, stack} = Enum.split_while(rest, &(String.trim(&1) != "stacktrace:"))

    base
    |> Map.merge(location)
    |> Map.merge(%{message: Enum.map(message, &dedent/1), at: first_frame(stack)})
  end

  # The first stack frame outside Elixir itself.
  defp first_frame([_label | frames]) do
    frames = Enum.map(frames, &String.trim/1)
    Enum.find(frames, List.first(frames), &(not runtime_frame?(&1)))
  end

  defp first_frame([]), do: nil

  defp runtime_frame?(frame) do
    case Regex.run(@frame_app, frame) do
      [_, app] -> app in @runtime_apps
      nil -> false
    end
  end

  # Compiler diagnostics start with "warning:" or "error:" and end with
  # the "└─ file:line" line that says where they are.
  defp diagnostics(lines) do
    {found, _open} =
      Enum.reduce(lines, {[], nil}, fn line, {found, open} ->
        cond do
          match = Regex.run(@diagnostic, line) ->
            [_, severity, message] = match
            {found, %{severity: severity(severity), message: String.trim(message)}}

          match = open && Regex.run(@diagnostic_at, line) ->
            [_, file, number] = match
            {[Map.merge(open, %{file: file, line: String.to_integer(number)}) | found], nil}

          true ->
            {found, open}
        end
      end)

    found |> Enum.uniq() |> Enum.sort_by(&{&1.file, &1.line, &1.message})
  end

  defp severity("error"), do: :error
  defp severity("warning"), do: :warning

  defp aborted(lines) do
    case Enum.find_index(lines, &String.starts_with?(&1, "== Compilation error in file ")) do
      nil ->
        nil

      index ->
        [_, file] = Regex.run(~r/^== Compilation error in file (.+) ==/, Enum.at(lines, index))
        reason = lines |> Enum.drop(index + 1) |> Enum.find(&String.starts_with?(&1, "** ("))
        %{file: file, reason: reason}
    end
  end

  # Elixir 1.20 prints "Result: 1/5 passed, 1 skipped" and "Failed: 4
  # tests"; older versions print "6 tests, 4 failures, 1 skipped". Either
  # way `tests` counts the tests that ran.
  defp counts(lines) do
    cond do
      line = Enum.find(lines, &String.starts_with?(&1, "Result: ")) ->
        {passed, tests} =
          cond do
            match = Regex.run(~r/^Result: (\d+)\/(\d+) passed/, line) ->
              [_, passed, tests] = match
              {String.to_integer(passed), String.to_integer(tests)}

            passed = number(~r/^Result: (\d+) passed/, line) ->
              {passed, passed}

            true ->
              {0, number(~r/^Result: (\d+) tests?/, line) || 0}
          end

        failed = Enum.find_value(lines, 0, &number(~r/^Failed: (\d+)/, &1))
        Map.merge(extras(line), %{tests: tests, passed: passed, failed: failed})

      line = Enum.find(lines, &Regex.match?(~r/^(\d+ doctests?, )?\d+ tests?, \d+ failures?/, &1)) ->
        extras = extras(line)
        total = (number(~r/^(\d+) doctests?, /, line) || 0) + number(~r/(\d+) tests?,/, line)
        tests = total - extras.skipped - extras.excluded - extras.invalid
        failed = number(~r/(\d+) failures?/, line)
        Map.merge(extras, %{tests: tests, passed: max(tests - failed, 0), failed: failed})

      true ->
        %{}
    end
  end

  defp extras(line) do
    for key <- [:skipped, :excluded, :invalid], into: %{} do
      {key, number(~r/(\d+) #{key}/, line) || 0}
    end
  end

  defp number(regex, line) do
    case Regex.run(regex, line) do
      [_, n | _] -> String.to_integer(n)
      nil -> nil
    end
  end

  # The last lines of a run that failed in a way the parser doesn't know.
  defp tail(lines) do
    lines
    |> Enum.reject(&(String.trim(&1) == "" or &1 =~ @progress))
    |> Enum.take(-@shown_tail)
  end

  ## Rendering

  defp headline(%{status: :ok} = check), do: "check passed: #{tests(check)}"

  defp headline(%{status: :failed, failed: failed} = check) when failed > 0,
    do: "check failed: #{failed} of #{tests(check)}"

  defp headline(%{status: :failed} = check), do: "check failed: #{tests(check)}"

  defp headline(%{status: :compile_error, aborted: %{file: file}}),
    do: "check failed to compile #{file}; the tests did not run"

  defp headline(%{status: :compile_error}),
    do: "check failed to compile; the tests did not run"

  defp headline(%{status: :timeout} = check) do
    seconds = div(check.limit_ms || Visor.Limits.check_timeout_ms(), 1000)
    "check stopped at the #{seconds} s time limit; the tests did not finish"
  end

  defp headline(check), do: "check failed: mix test exited with status #{check.exit}"

  defp tests(check) do
    extras =
      [:skipped, :excluded, :invalid]
      |> Enum.map(&{&1, Map.fetch!(check, &1)})
      |> Enum.filter(fn {_key, n} -> n > 0 end)
      |> Enum.map_join(fn {key, n} -> ", #{n} #{key}" end)

    "#{check.tests} #{if check.tests == 1, do: "test", else: "tests"}#{extras}"
  end

  # Checks compare only when both ran the tests.
  defp comparable?(_check, nil), do: false

  defp comparable?(check, previous),
    do: check.status in [:ok, :failed] and previous.status in [:ok, :failed]

  defp comparison(before, now) do
    if MapSet.size(before) > 0 or MapSet.size(now) > 0 do
      fixed = before |> MapSet.difference(now) |> Enum.sort()
      new = MapSet.size(MapSet.difference(now, before))

      [
        "since the last check: #{length(fixed)} fixed, #{new} new, " <>
          "#{MapSet.size(now) - new} still failing",
        if(fixed != [], do: "fixed: " <> names(fixed))
      ]
    end
  end

  defp failing(check), do: MapSet.new(check.failures, &{&1.module, &1.name})

  defp names(ids) do
    {shown, hidden} = Enum.split(ids, @shown_names)
    shown = Enum.map_join(shown, ", ", fn {module, name} -> ~s["#{name}" (#{module})] end)
    if hidden != [], do: shown <> " and #{length(hidden)} more", else: shown
  end

  defp failure_lines(%{failures: []}, _before), do: nil

  defp failure_lines(check, before) do
    {shown, hidden} = Enum.split(check.failures, @shown_failures)

    lines =
      Enum.flat_map(shown, fn failure ->
        new? = before != nil and not MapSet.member?(before, {failure.module, failure.name})
        [failure_head(failure, new?) | failure_body(failure)]
      end)

    ["failures:" | lines] ++ if(hidden != [], do: ["  and #{length(hidden)} more"], else: [])
  end

  defp failure_head(%{kind: "module"} = failure, new?),
    do: clip("  #{failure.module}: #{failure.name}#{if new?, do: ", new"}")

  defp failure_head(failure, new?) do
    where = if failure.file, do: "#{failure.file}:#{failure.line} ", else: ""
    clip(~s[  #{where}"#{failure.name}" (#{failure.module})#{if new?, do: ", new"}])
  end

  defp failure_body(failure) do
    {shown, hidden} = Enum.split(failure.message, @shown_message_lines)
    lines = Enum.map(shown, &clip("    " <> &1))
    lines = if hidden != [], do: lines ++ ["    …"], else: lines
    if failure.at, do: lines ++ [clip("    at " <> failure.at)], else: lines
  end

  defp error_lines(check) do
    {shown, hidden} =
      check.diagnostics
      |> Enum.filter(&(&1.severity == :error))
      |> Enum.split(@shown_diagnostics)

    # The reason a compile stopped, unless it only points at the errors.
    reason =
      case check.aborted do
        %{reason: "** (" <> _ = reason} ->
          unless reason =~ "errors have been logged", do: clip("  " <> reason)

        _ ->
          nil
      end

    lines =
      Enum.reject([reason | Enum.map(shown, &diagnostic_line/1)], &is_nil/1) ++
        if(hidden != [], do: ["  and #{length(hidden)} more"], else: [])

    if lines != [], do: ["errors:" | lines]
  end

  defp tail_lines(%{tail: []}), do: nil
  defp tail_lines(check), do: ["output ends with:" | Enum.map(check.tail, &clip("  " <> &1))]

  defp warning_lines(check, changed) do
    warnings = Enum.filter(check.diagnostics, &(&1.severity == :warning))
    {mine, others} = Enum.split_with(warnings, &(&1.file in changed))
    {shown, hidden} = Enum.split(mine, @shown_diagnostics)

    cond do
      warnings == [] ->
        nil

      mine == [] ->
        "#{Format.count(length(others), "warning")}, none in files this session changed"

      true ->
        ["warnings in files this session changed:" | Enum.map(shown, &diagnostic_line/1)] ++
          if(hidden != [], do: ["  and #{length(hidden)} more"], else: []) ++
          if(others != [],
            do: ["#{Format.count(length(others), "more warning")} in other files"],
            else: []
          )
    end
  end

  defp diagnostic_line(d), do: clip("  #{d.file}:#{d.line}: #{d.message}")

  defp clip(line) do
    if String.length(line) > @line_chars,
      do: String.slice(line, 0, @line_chars - 1) <> "…",
      else: line
  end

  defp leading_spaces(line), do: byte_size(line) - byte_size(String.trim_leading(line, " "))

  defp dedent(line) do
    drop = min(leading_spaces(line), @body_indent)
    binary_part(line, drop, byte_size(line) - drop)
  end
end
