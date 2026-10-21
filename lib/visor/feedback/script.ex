defmodule Visor.Feedback.Script do
  @moduledoc """
  The result of an `elixir` script as the model sees it: whether the
  script finished, what its V calls changed and ran, the checks it made,
  what it printed and its value.

      ok: 4 calls
      changed: lib/app.ex (2 edits), test/app_test.exs (edit)
      check passed: 31 tests
      => :ok

  It has no timings or process ids, so the same script on the same files
  always gives the same text. Output too long to show is cut and kept
  behind a ref such as `r3`, which `V.output/2` reads back.
  """

  alias Visor.Tools

  @max_value_bytes 24_000
  @max_printed_bytes 8_000
  @max_command_chars 100
  # Bounds on inspecting a value, which is cut at @max_value_bytes anyway;
  # what goes past the cut is kept behind a ref.
  @max_inspect_items 10_000
  @max_inspect_bytes 2_000_000

  @doc """
  Returns `{:ok, text}` or `{:error, text}` for a Dune result and the
  records of the script's V calls, in order. `keep` stores the whole of
  an output that was cut and returns its ref, or nil when nothing is kept.
  """
  def render(result, calls, keep \\ fn _text -> nil end) do
    text =
      [
        headline(result, calls),
        changed(calls),
        ran(calls),
        for(%{status: :ok, check: summary} <- calls, do: summary),
        printed(result.stdio, keep),
        value(result, calls, keep)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    {if(match?(%Dune.Success{}, result), do: :ok, else: :error), Tools.clip(text)}
  end

  defp headline(%Dune.Success{}, calls), do: "ok: #{count(calls)}"

  defp headline(failure, calls) do
    last = List.last(calls)
    stop = stopped(failure)

    cond do
      match?(%{status: :error}, last) ->
        "failed at call #{last.n}: V.#{last.text}\n" <> indent(last.error)

      stop && match?(%{status: :running}, last) ->
        "#{stop} while call #{last.n} was running: V.#{last.text}"

      stop ->
        "#{stop} after #{count(calls)}"

      true ->
        "failed after #{count(calls)}:\n" <> indent(without_stacktrace(failure.message))
    end
  end

  defp stopped(%Dune.Failure{type: :timeout, message: message}) do
    case Regex.run(~r/(\d+)ms/, message) do
      [_, ms] -> "stopped at the #{div(String.to_integer(ms), 1000)} s time limit"
      nil -> "stopped at the time limit"
    end
  end

  defp stopped(%Dune.Failure{type: :memory}), do: "stopped at the memory limit"
  defp stopped(%Dune.Failure{type: :reductions}), do: "stopped at the work limit"
  defp stopped(_failure), do: nil

  defp changed(calls) do
    files =
      for(%{status: :ok, changed: path} = call <- calls, do: {path, call.name})
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.sort()
      |> Enum.map(fn {path, names} -> "#{path} (#{operations(names)})" end)

    if files != [], do: "changed: " <> Enum.join(files, ", ")
  end

  defp operations(names) do
    names
    |> Enum.frequencies()
    |> Enum.sort()
    |> Enum.map_join(", ", fn
      {name, 1} -> "#{name}"
      {name, n} -> "#{n} #{name}s"
    end)
  end

  defp ran(calls) do
    for %{status: :ok, ran: command} = call <- calls do
      status = if call.exit == :timeout, do: "timed out", else: "exit #{call.exit}"
      status = if call.ref, do: "#{status}, output #{call.ref}", else: status
      "ran: #{one_line(command)} (#{status})"
    end
  end

  defp one_line(command) do
    line = command |> String.split("\n", parts: 2) |> hd()

    if line != command or String.length(line) > @max_command_chars,
      do: String.slice(line, 0, @max_command_chars) <> "…",
      else: line
  end

  defp printed(stdio, keep) do
    if String.trim(stdio) != "" do
      text = String.trim_trailing(stdio)
      ["printed:", cut(text, text, @max_printed_bytes, keep)]
    end
  end

  # A value a call already showed (a check's result) isn't repeated.
  defp value(%Dune.Success{value: value} = success, calls, keep) do
    unless Enum.any?(calls, &(Map.has_key?(&1, :value) and &1.value === value)) do
      inspected = inspected(success)
      # The whole of a long string is kept as text, so V.output/2 can read
      # it by lines.
      whole = if is_binary(value) and String.valid?(value), do: value, else: inspected
      "=> " <> cut(inspected, whole, @max_value_bytes, keep)
    end
  end

  defp value(_failure, _calls, _keep), do: nil

  # Dune inspects with Elixir's default limits, which cut strings at 4 KB
  # and lists at 50 items. Inspect again with room for everything up to
  # the cut, unless the value holds atoms Dune renamed (atoms the script
  # made up), whose names only Dune's own inspect knows.
  defp inspected(%Dune.Success{value: value, inspected: inspected}) do
    if renamed_atoms?(value) do
      inspected
    else
      inspect(value,
        pretty: true,
        limit: @max_inspect_items,
        printable_limit: @max_inspect_bytes,
        custom_options: [sort_maps: true]
      )
    end
  end

  defp renamed_atoms?(atom) when is_atom(atom),
    do: atom |> Atom.to_string() |> String.contains?(["Dune_Atom_", "Dune_atom_"])

  defp renamed_atoms?([head | tail]), do: renamed_atoms?(head) or renamed_atoms?(tail)
  defp renamed_atoms?(tuple) when is_tuple(tuple), do: renamed_atoms?(Tuple.to_list(tuple))
  defp renamed_atoms?(map) when is_map(map), do: renamed_atoms?(Map.to_list(map))
  defp renamed_atoms?(_other), do: false

  defp cut(text, whole, max_bytes, keep) do
    if byte_size(text) <= max_bytes do
      text
    else
      kept =
        case keep.(whole) do
          nil -> ""
          ref -> "; the whole output is #{ref}"
        end

      Tools.truncate(text, max_bytes) <> "\n[cut at #{div(max_bytes, 1000)} KB#{kept}]"
    end
  end

  defp count([_]), do: "1 call"
  defp count(calls), do: "#{length(calls)} calls"

  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))

  # Failures end with our own stack frames, which say nothing about the
  # script.
  defp without_stacktrace(message) do
    message
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s+\(\w+ [\w.-]+\) /, &1))
    |> Enum.join("\n")
  end
end
