defmodule Visor.FormatTest do
  use ExUnit.Case, async: true

  alias Visor.Format

  test "shortens large numbers to a few digits" do
    assert Enum.map([nil, 527, 1_000, 73_744, 999_999, 1_048_000, 1_203_878], &Format.short/1) ==
             ["–", "527", "1k", "73.7k", "1M", "1.05M", "1.2M"]
  end
end
