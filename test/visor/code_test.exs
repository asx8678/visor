defmodule Visor.CodeTest do
  use ExUnit.Case, async: false

  alias Visor.{Agent, Code, Feedback}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:visor, :workspace)
    Application.put_env(:visor, :workspace, tmp_dir)
    on_exit(fn -> Application.put_env(:visor, :workspace, previous) end)

    File.mkdir_p!(Path.join(tmp_dir, "lib/app"))
    File.write!(Path.join(tmp_dir, "lib/app.ex"), "defmodule App do\n  def a, do: 1\nend\n")
    File.write!(Path.join(tmp_dir, "lib/app/b.ex"), "defmodule App.B do\n  def b, do: 2\nend\n")
    File.write!(Path.join(tmp_dir, ".env"), "DEEPSEEK_API_KEY=secret\n")
    :ok
  end

  # A session with a feedback collector, so outputs are kept behind refs.
  defp session do
    id = "code-test-#{System.unique_integer([:positive])}"
    start_supervised!({Feedback, id: id})
    %{session: id, call_id: "c1"}
  end

  test "runs a script that makes several calls in one process" do
    script = """
    for path <- V.glob("lib/**/*.ex") do
      {Path.basename(path), length(V.grep("def ", path))}
    end
    """

    assert {:ok, ~s(ok: 3 calls\n=> [{"app.ex", 1}, {"b.ex", 1}])} = Code.run(script, %{})
  end

  test "returns printed output with the value" do
    assert {:ok, "ok: 1 call\nprinted:\napp/app.ex\n=> 1"} =
             Code.run(~S|IO.puts(Enum.join(V.ls("lib"))); 1|, %{})
  end

  test "edits and writes files in the project, and lists them" do
    script = """
    :ok = V.edit("lib/app.ex", "def a, do: 1", "def a, do: 10")
    :ok = V.edit("./lib/app.ex", "def a, do: 10", "def a, do: 11")
    :ok = V.write("notes/todo.md", "check a/0")
    {V.read("lib/app.ex"), V.read("notes/todo.md")}
    """

    assert {:ok, result} = Code.run(script, %{})

    assert result =~
             ~r/\Aok: 5 calls\nchanged: lib\/app.ex \(2 edits\), notes\/todo.md \(write\)\n=> /

    assert result =~ "def a, do: 11"
    assert result =~ "check a/0"
  end

  test "stops the script at the first failing call and says what changed before it" do
    assert {:error, ~s|failed at call 1: V.read("missing.ex")\n  missing.ex does not exist.|} =
             Code.run(~S|V.read("missing.ex"); V.ls(".")|, %{})

    script = ~S"""
    V.edit("lib/app.ex", "def a, do: 1", "def a, do: 2")
    V.edit("lib/app.ex", "def", "fn")
    """

    assert {:error, message} = Code.run(script, %{})

    assert message ==
             """
             failed at call 2: V.edit("lib/app.ex", "def", "fn")
               The text to replace appears 2 times in lib/app.ex. Include more of the \
             surrounding text so it appears once.
             changed: lib/app.ex (edit)\
             """
  end

  test "reports a failure in the script itself" do
    assert {:error, message} = Code.run(~S|V.ls("lib"); {:ok, _} = :error|, %{})
    assert message =~ ~r/\Afailed after 1 call:\n  \*\* \(MatchError\) no match/
    refute message =~ "lib/v.ex"
  end

  test "keeps scripts away from secrets and the rest of the system" do
    assert {:error, message} = Code.run(~S|V.read(".env")|, %{})
    assert message =~ "holds secrets"

    assert {:ok, "ok: 1 call\n=> []"} = Code.run(~S|V.glob(".env*")|, %{})
    assert {:ok, "ok: 1 call\n=> []"} = Code.run(~S|V.glob("{..,lib}/*.secret")|, %{})

    for script <- [~S|File.read!(".env")|, ~S|System.cmd("ls", [])|, ~S|spawn(fn -> 1 end)|] do
      assert {:error, message} = Code.run(script, %{})
      assert message =~ "failed after 0 calls:"
      assert message =~ "DuneRestrictedError"
    end
  end

  test "lists the commands a script ran and keeps the output of failed ones" do
    context = session()
    script = ~S|V.sh("echo fine"); V.sh("echo broken; exit 3").status|

    assert {:ok,
            "ok: 2 calls\nran: echo fine (exit 0)\nran: echo broken; exit 3 (exit 3, output r1)\n=> 3"} =
             Code.run(script, context)

    assert {:ok, ~s(ok: 1 call\n=> "broken\\n")} = Code.run(~S|V.output("r1")|, context)
  end

  test "cuts a long value and keeps all of it for V.output" do
    context = session()
    script = ~S|Enum.map_join(1..5000, "\n", &"line #{&1}")|

    assert {:ok, result} = Code.run(script, context)
    assert result =~ ~r/\Aok: 0 calls\n=> "line 1\\nline 2/
    assert String.ends_with?(result, "\n[cut at 24 KB; the whole output is r1]")

    assert {:ok, ~s(ok: 1 call\n=> "line 2\\nline 3")} =
             Code.run(~S|V.output("r1", 2..3)|, context)

    assert {:error, message} = Code.run(~S|V.output("r1", 6000..6001)|, context)
    assert message =~ "r1 has only 5000 lines."

    assert {:error, message} = Code.run(~S|V.output("r9")|, context)
    assert message =~ "There is no output r9."
  end

  test "gives the same text for the same script on the same files" do
    context = session()

    script = ~S"""
    V.write("notes/a.md", "one")
    V.edit("notes/a.md", "one", "two")
    IO.puts("wrote it")
    V.sh("ls notes; exit 1").status
    """

    results = for _ <- 1..2, do: Code.run(script, context)

    assert [{:ok, text}, {:ok, text}] = results

    assert text ==
             "ok: 3 calls\nchanged: notes/a.md (edit, write)\n" <>
               "ran: ls notes; exit 1 (exit 1, output r1)\nprinted:\nwrote it\n=> 1"

    refute text =~ ~r/\d+ ?ms\b/
  end

  test "reports each call to the session's console" do
    Agent.subscribe("code-test")

    assert {:ok, _} =
             Code.run(~S|V.ls("."); V.read("lib/app.ex")|, %{session: "code-test", call_id: "c1"})

    assert_receive {:agent, {:code_call, "c1", %{n: 1, text: ~s|ls(".")|, status: :running}}}
    assert_receive {:agent, {:code_call, "c1", %{n: 1, status: :ok, ms: ms}}} when is_integer(ms)

    assert_receive {:agent,
                    {:code_call, "c1", %{n: 2, text: ~s|read("lib/app.ex")|, status: :ok}}}
  end
end
