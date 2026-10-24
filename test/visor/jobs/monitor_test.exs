defmodule Visor.Jobs.MonitorTest do
  use ExUnit.Case, async: true

  alias Visor.Jobs.Monitor

  # The lines the model hears of from pieces of output, the last line
  # included when the output ends without a newline.
  defp lines(monitor, pieces) do
    {monitor, lines} =
      Enum.reduce(pieces, {monitor, []}, fn piece, {monitor, lines} ->
        {monitor, more} = Monitor.feed(monitor, piece)
        {monitor, lines ++ more}
      end)

    lines ++ Monitor.close(monitor)
  end

  test "frames lines across pieces of output, and keeps those with its text" do
    pieces = ["boot\nREA", "DY on 4000\nother\n", "READY again"]
    assert lines(Monitor.new("READY"), pieces) == ["READY on 4000", "READY again"]
    assert lines(Monitor.new(true), pieces) == ["boot", "READY on 4000", "other", "READY again"]
  end

  test "skips empty lines and the line it told of again, and blanks control characters" do
    pieces = ["\n  \nok\r\nok\n", "\e[32mok\e[0m\nok\n"]
    assert lines(Monitor.new(true), pieces) == ["ok", "[32mok [0m", "ok"]
  end

  test "joins a character split between pieces, and cuts a long line" do
    assert lines(Monitor.new(true), ["caf" <> <<0xC3>>, <<0xA9>> <> "\n"]) == ["café"]

    long = String.duplicate("x", 9_000)
    assert lines(Monitor.new(true), [long]) == [String.duplicate("x", 480) <> "…"]
  end

  test "keeps a batch's newest lines, and counts the older ones it leaves out" do
    batch = Monitor.add(nil, ["l1", "l2", "l3", "l4", "l5"])
    assert batch == %{lines: ["l1", "l2", "l3", "l4", "l5"], omitted: 0}

    batch = Monitor.add(batch, ["l6", "l7", "l8", "l9", "l10"])
    assert batch == %{lines: ["l3", "l4", "l5", "l6", "l7", "l8", "l9", "l10"], omitted: 2}

    assert Monitor.merge(batch, %{lines: ["l11"], omitted: 4}) ==
             %{lines: ["l4", "l5", "l6", "l7", "l8", "l9", "l10", "l11"], omitted: 7}
  end
end
