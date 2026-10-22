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

  @doc ~S|A count with its noun: "1 turn", "1,200 turns".|
  def count(1, noun), do: "1 #{noun}"
  def count(n, noun), do: "#{number(n)} #{noun}s"

  @doc ~S|Milliseconds as they read: "850 ms", "7.1 s", nil "–".|
  def seconds(nil), do: "–"
  def seconds(ms) when ms < 1000, do: "#{ms} ms"
  def seconds(ms), do: "#{:erlang.float_to_binary(ms / 1000, decimals: 1)} s"
end
