defmodule Visor.CallsTest do
  # V.calls finds call sites in the parsed code, after Vibe's AST search.
  use ExUnit.Case, async: false

  alias Visor.Calls

  @moduletag :tmp_dir

  @source """
  defmodule Demo.A do
    alias Demo.B
    alias Demo.C, as: Cee
    alias Demo.{E, F}
    import Demo.D, only: [d: 1]

    def run(x) do
      B.go(x)
      Demo.B.go(x, 2)
      x |> B.go()
      Cee.go(1)
      d(x)
      helper(x)
      f = &B.go/1
      :ets.lookup(:t, x)
      E.go(F.go(x))
      # B.go(x) in a comment, and "B.go(x)" in a string, aren't calls
      f
    end

    defp helper(x), do: x

    defmodule Inner do
      def go(x), do: x
    end

    def inner(x), do: Inner.go(x)
  end
  """

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:visor, :workspace)
    Application.put_env(:visor, :workspace, dir)
    on_exit(fn -> Application.put_env(:visor, :workspace, previous) end)

    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/a.ex"), @source)
    :ok
  end

  defp lines(ref) do
    assert {:ok, calls} = Calls.find(ref, "lib")
    Enum.map(calls, & &1.line)
  end

  test "finds calls through aliases, pipes, captures and imports, by arity" do
    assert lines("Demo.B.go/1") == [8, 10, 14]
    assert lines("Demo.B.go/2") == [9]
    assert lines("Demo.B.go") == [8, 9, 10, 14]
    assert lines("Demo.C.go/1") == [11]
    assert lines("Demo.D.d/1") == [12]
    assert lines("Demo.E.go") == [16]
    assert lines("Demo.F.go") == [16]
    assert lines(":ets.lookup/2") == [15]
  end

  test "finds a module's own calls, not its definitions, and nested modules' names" do
    assert lines("Demo.A.helper/1") == [13]
    assert lines("Demo.A.run/1") == []
    assert lines("Demo.A.Inner.go/1") == [27]

    assert {:ok, [%{file: "lib/a.ex", line: 8, text: "B.go(x)"} | _]} =
             Calls.find("Demo.B.go/1", "lib/a.ex")
  end

  test "is a V call, and says what a reference is" do
    assert {:ok, text} = Visor.Code.run(~S[V.calls("Demo.B.go/2") |> length()], %{})
    assert text =~ "=> 1"
    assert {:error, message} = Calls.find("go", "lib")
    assert message =~ "isn't a function: give Module.function/arity"
  end
end
