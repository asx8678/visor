defmodule Visor.Feedback.ScriptTest do
  use ExUnit.Case, async: true

  alias Visor.Feedback.Script

  defp ok(value, stdio \\ ""),
    do: %Dune.Success{value: value, inspected: inspect(value), stdio: stdio}

  defp call(n, name, text, fields \\ %{}),
    do: Map.merge(%{n: n, name: name, text: text, status: :ok, ms: 3}, fields)

  test "says which call was running when the script hit a limit" do
    calls = [call(1, :ls, ~s|ls(".")|), call(2, :check, "check()", %{status: :running})]
    timeout = %Dune.Failure{type: :timeout, message: "Execution timeout - 120000ms", stdio: ""}

    assert Script.render(timeout, calls) ==
             {:error, "stopped at the 120 s time limit while call 2 was running: V.check()"}

    memory = %Dune.Failure{type: :memory, message: "Execution stopped", stdio: "partial\n"}

    assert Script.render(memory, Enum.take(calls, 1)) ==
             {:error, "stopped at the memory limit after 1 call\nprinted:\npartial"}
  end

  test "groups the changes to each file, sorted by path" do
    calls = [
      call(1, :edit, "edit(...)", %{changed: "lib/b.ex"}),
      call(2, :write, "write(...)", %{changed: "lib/a.ex"}),
      call(3, :edit, "edit(...)", %{changed: "lib/a.ex"}),
      call(4, :edit, "edit(...)", %{changed: "lib/a.ex"})
    ]

    assert Script.render(ok(:ok), calls) ==
             {:ok, "ok: 4 calls\nchanged: lib/a.ex (2 edits, write), lib/b.ex (edit)\n=> :ok"}
  end

  test "shows commands on one line each" do
    calls = [
      call(1, :sh, "sh(...)", %{ran: "mix format\nmix compile", exit: 0, ref: nil}),
      call(2, :sh, "sh(...)", %{ran: "sleep 100", exit: :timeout, ref: "r4"})
    ]

    assert {:ok, text} = Script.render(ok(:done), calls)

    assert text ==
             "ok: 2 calls\nran: mix format… (exit 0)\nran: sleep 100 (timed out, output r4)\n=> :done"
  end

  test "doesn't repeat a check's result as the value" do
    result = %{status: :ok, tests: 3}
    calls = [call(1, :check, "check()", %{check: "check passed: 3 tests", value: result})]

    assert Script.render(ok(result), calls) == {:ok, "ok: 1 call\ncheck passed: 3 tests"}

    assert Script.render(ok(:other), calls) ==
             {:ok, "ok: 1 call\ncheck passed: 3 tests\n=> :other"}
  end

  test "cuts long output and keeps all of it" do
    long = String.duplicate("line\n", 6_000)

    keep = fn text ->
      send(self(), {:kept, text})
      "r7"
    end

    assert {:ok, text} = Script.render(ok(:ok, long), [], keep)
    assert text =~ ~r/\Aok: 0 calls\nprinted:\nline\n/
    assert text =~ "\n[cut at 8 KB; the whole output is r7]\n=> :ok"
    assert_received {:kept, kept} when kept == binary_part(long, 0, byte_size(long) - 1)

    # Without a session nothing is kept, and the cut says so by naming no ref.
    assert {:ok, text} = Script.render(ok(String.duplicate("x", 30_000)), [])
    assert text =~ ~r/\n\[cut at 24 KB\]\z/
  end
end
