defmodule Visor.Format do
  @moduledoc """
  How numbers, counts and times read wherever Visor shows them: the
  console, tool results and `mix visor.log`.
  """

  @doc ~S|An integer with thousands separators: `15768` reads "15,768", nil "–".|
  def number(nil), do: "–"

  def number(n) when is_integer(n),
    do: n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+$)/, ",")

  def number(n), do: to_string(n)

  @doc ~S|A large number in short: 1_048_000 reads "1.05M", 73_744 "73.7k", 527 "527".|
  def short(nil), do: "–"
  def short(n) when n >= 999_950, do: decimals(n / 1_000_000, 2) <> "M"
  def short(n) when n >= 1_000, do: decimals(n / 1_000, 1) <> "k"
  def short(n), do: number(n)

  # Rounded, without trailing zeros: 1.20 reads "1.2", 1.00 "1".
  defp decimals(x, places) do
    x
    |> :erlang.float_to_binary(decimals: places)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  @doc ~S|A count with its noun: "1 turn", "1,200 turns".|
  def count(1, noun), do: "1 #{noun}"
  def count(n, noun), do: "#{number(n)} #{noun}s"

  @doc ~S|Milliseconds as they read: "850 ms", "7.1 s", nil "–".|
  def seconds(nil), do: "–"
  def seconds(ms) when ms < 1000, do: "#{ms} ms"
  def seconds(ms), do: "#{:erlang.float_to_binary(ms / 1000, decimals: 1)} s"

  @doc "A length of time in ms, as `\"3.2 s\"`, `\"4 min 10 s\"` or `\"2 h 5 min\"`."
  def duration(nil), do: "–"
  def duration(ms) when ms < 60_000, do: seconds(ms)

  def duration(ms) when ms < 3_600_000,
    do: "#{div(ms, 60_000)} min #{div(rem(ms, 60_000), 1000)} s"

  def duration(ms), do: "#{div(ms, 3_600_000)} h #{div(rem(ms, 3_600_000), 60_000)} min"
end
