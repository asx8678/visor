defmodule Visor.Jobs.Monitor do
  @line_chars 2_048
  @preview_chars 480
  @previews 8

  @moduledoc """
  The lines a monitored job (`V.sh(cmd, monitor: "text")`) tells the model
  of, after pi-fabric's shell monitors. The job's output is framed into
  lines as it comes; each keeps its first #{@line_chars} characters, with
  control characters as spaces, trimmed. A line is told of when it isn't
  empty, holds the text (case-sensitive, not a regex) and isn't the last
  line told of again. No model call or poll: the job's output drives it.

  A batch is what the agent hasn't heard yet: the newest #{@previews} lines,
  each cut to #{@preview_chars} characters, and how many older ones it left
  out. The job's log has them all.
  """

  defstruct match: nil, line: "", cut: false, previous: nil

  @doc "A monitor for the lines that hold `match`, or for every line (`true`)."
  def new(true), do: %__MODULE__{}
  def new(match) when is_binary(match), do: %__MODULE__{match: match}

  @doc """
  Takes a piece of the job's output. Returns the monitor and the lines it
  ended that the model should hear of.
  """
  def feed(%__MODULE__{} = monitor, data) do
    [first | rest] = String.split(data, "\n")

    {monitor, lines} =
      Enum.reduce(rest, {add_text(monitor, first), []}, fn part, {monitor, lines} ->
        {monitor, line} = end_line(monitor)
        {add_text(monitor, part), if(line, do: [line | lines], else: lines)}
      end)

    {monitor, Enum.reverse(lines)}
  end

  @doc "The job's last line when its output didn't end with a newline: `[]` or `[line]`."
  def close(%__MODULE__{} = monitor) do
    case end_line(monitor) do
      {_monitor, nil} -> []
      {_monitor, line} -> [line]
    end
  end

  @doc "Batch `batch` (nil for none yet) with `lines` after it."
  def add(nil, lines), do: add(%{lines: [], omitted: 0}, lines)

  def add(%{lines: held, omitted: omitted}, lines) do
    all = held ++ lines
    drop = max(length(all) - @previews, 0)
    %{lines: Enum.drop(all, drop), omitted: omitted + drop}
  end

  @doc "Two batches as one: `held`, then `batch`."
  def merge(nil, batch), do: batch
  def merge(held, batch), do: add(%{held | omitted: held.omitted + batch.omitted}, batch.lines)

  # A line keeps its first characters (up to four bytes each); the rest
  # only marks it as cut.
  defp add_text(monitor, text) do
    room = max(@line_chars * 4 - byte_size(monitor.line), 0)

    if byte_size(text) > room,
      do: %{monitor | line: monitor.line <> binary_part(text, 0, room), cut: true},
      else: %{monitor | line: monitor.line <> text}
  end

  defp end_line(monitor) do
    {line, cut} = clean(monitor.line, monitor.cut)
    monitor = %{monitor | line: "", cut: false}

    cond do
      line == "" -> {monitor, nil}
      monitor.match && not String.contains?(line, monitor.match) -> {monitor, nil}
      line == monitor.previous -> {monitor, nil}
      true -> {%{monitor | previous: line}, preview(line, cut)}
    end
  end

  defp clean(line, cut) do
    line =
      line
      |> String.replace_invalid()
      |> String.replace(~r/[\x{0}-\x{1f}\x{7f}-\x{9f}]/u, " ")
      |> String.trim()

    if String.length(line) > @line_chars,
      do: {String.slice(line, 0, @line_chars), true},
      else: {line, cut}
  end

  defp preview(line, cut) do
    if cut or String.length(line) > @preview_chars,
      do: String.slice(line, 0, @preview_chars) <> "…",
      else: line
  end
end
