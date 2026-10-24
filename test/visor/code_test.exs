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

  test "times a command out at the timeout it asks for" do
    assert {:ok, message} = Code.run(~S|V.sh("sleep 3; echo late", timeout: 0.5).status|, %{})
    assert message =~ "ran: sleep 3; echo late (timed out)"
    assert message =~ "=> :timeout"
  end

  test "ends a command a second before its script's own limit" do
    started = System.monotonic_time(:millisecond)
    script = ~S|V.sh("sleep 10", timeout: 60).status|
    assert {:ok, message, _calls} = Code.execute(script, %{timeout_ms: 2_500})
    assert message =~ "=> :timeout"
    assert System.monotonic_time(:millisecond) - started < 2_500
  end

  test "takes only timeout: as an option, in seconds" do
    assert {:error, message} = Code.run(~S|V.sh("ls", cwd: "lib")|, %{})
    assert message =~ "The options are timeout: (seconds) and background: true, not [:cwd]."

    assert {:error, message} = Code.run(~S|V.sh("ls", timeout: "5")|, %{})
    assert message =~ ~s(timeout: is a number of seconds, not "5".)
  end

  test "raises a script's time limit to what its call asks, never lowers it" do
    assert Code.timeout_ms(nil) == 120_000
    assert Code.timeout_ms(30) == 120_000
    assert Code.timeout_ms(300) == 300_000
    assert Code.timeout_ms(10_000) == 900_000
    assert Code.timeout_ms("300") == 120_000
  end

  test "runs read-only calls at once, each reported as its own call" do
    script = ~S"""
    V.all([{:sh, "sleep 1; echo a"}, {:sh, "sleep 1; echo b"}, {:sh, ["sleep 1; echo c"]}])
    |> Enum.map(fn {:ok, %{output: output}} -> output end)
    """

    started = System.monotonic_time(:millisecond)
    assert {:ok, text, calls} = Code.execute(script, session())
    assert System.monotonic_time(:millisecond) - started < 2_000

    assert text =~ ~s(=> ["a\\n", "b\\n", "c\\n"])
    for name <- ~w(a b c), do: assert(text =~ "ran: sleep 1; echo #{name} (exit 0)")
    assert [1, 2, 3, 4] = Enum.map(calls, & &1.n)
    assert [:all, :sh, :sh, :sh] = Enum.map(calls, & &1.name)
  end

  test "gives each call of V.all its own result, failed or not" do
    script = ~S"""
    V.all([{:read, "lib/app.ex"}, {:read, "lib/nope.ex"}]) |> Enum.map(&elem(&1, 0))
    """

    assert {:ok, text} = Code.run(script, %{})
    assert text =~ "=> [:ok, :error]"

    for script <- [
          ~S|V.all([{:write, ["a.txt", "x"]}])|,
          ~S|V.all([{:sh, ["sleep 1", [background: true]]}])|,
          ~S|V.attempt(fn -> V.all([{:ls, []}]) end)|
        ] do
      assert {:error, message} = Code.run(script, %{})
      assert message =~ ~r/V.all (runs only|can't run inside V.attempt)/
    end
  end

  test "hints at the right call for the mistakes models make" do
    hints = %{
      ~S|V.read_file("mix.exs")| => "V has no read_file; did you mean V.read(path)?",
      ~S|V.edit("a.ex", old: "x", new: "y")| =>
        "V.edit has no 2-argument form, and no keyword options: V.edit(path, old, new).",
      ~S|V.grep("x", "lib", 3)| => ~S|V.grep(pattern, path \\ ".")|,
      ~S|V.read(123)| => "the arguments don't fit V.read(path)",
      ~S|File.read!("mix.exs")| => "use V.read(path).",
      ~S|Path.wildcard("*")| => "use V.glob(pattern).",
      ~S|System.cmd("ls", [])| => "use V.sh(command).",
      ~S|File.stat("x")| => "only through V, which has ",
      ~S|import Enum; map([1], & &1)| => "write a module's full name",
      ~S|try do 1 rescue _ -> 2 end| => "check first, such as V.exists?(path)"
    }

    for {script, hint} <- hints do
      assert {:error, message} = Code.run(script, %{})
      assert [_error, line] = String.split(message, "\nhint: ")
      assert line =~ hint, "#{script} gave: #{line}"
    end

    # No hint for an error it knows nothing about.
    assert {:error, message} = Code.run(~S|{:ok, _} = :error|, %{})
    refute message =~ "hint:"
  end

  test "checks whether a file exists, since a script can't rescue a failed read" do
    assert {:ok, "ok: 2 calls\n=> {true, false}"} =
             Code.run(~S|{V.exists?("lib/app.ex"), V.exists?("lib/nope.ex")}|, %{})

    assert {:error, message} = Code.run(~S|V.exists?("../x")|, %{})
    assert message =~ "../x is outside the project folder."
  end

  test "greps with a ~r regex, options included, or explains what it takes" do
    assert {:ok, "ok: 1 call\n=> 2"} =
             Code.run(~S'V.grep(~r/DEFMODULE/i, "lib") |> length()', %{})

    assert {:error, message} = Code.run(~S|V.grep(:def, "lib")|, %{})
    assert message =~ "V.grep takes a regex, as a string or ~r//, and a path string, not :def"
  end

  test "stops a script at 2,000 V calls" do
    assert {:ok, "ok: 2,000 calls\n=> :done"} =
             Code.run(~S|for _ <- 1..2000, do: V.exists?("lib"); :done|, %{})

    assert {:error, message} = Code.run(~S|for _ <- 1..2001, do: V.exists?("lib"); :done|, %{})
    assert message =~ "failed after 2,000 calls:"
    assert message =~ "The script made 2,000 V calls, the most one script may make."
  end

  test "says how to write a file too long for one script" do
    code = ~s|V.write("big.html", "#{String.duplicate("x", 20_000)}")|
    assert {:error, message} = Code.run(code, %{})

    assert message ==
             "not run: the script is 20,023 characters, over the limit of 20,000. Write a " <>
               "long file in parts: the first with V.write, each next one with " <>
               "V.write(path, V.read(path) <> part)."

    assert {:ok, _} = Code.run(String.slice(code, 0, 19_980) <> ~s|")|, %{})
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

    assert {:ok, "ok: 1 call\n=> text, 7 bytes:\nbroken\n"} =
             Code.run(~S|V.output("r1")|, context)
  end

  test "cuts a long value and keeps all of it for V.output" do
    context = session()
    script = ~S|Enum.map_join(1..5000, "\n", &"line #{&1}")|

    assert {:ok, result} = Code.run(script, context)
    # Text reads as itself, line by line, rather than as one escaped string.
    assert result =~ ~r/\Aok: 0 calls\n=> text, 48,892 bytes:\nline 1\nline 2\n/
    assert String.ends_with?(result, "\n[cut at 24 KB; the whole output is r1]")

    assert {:ok, "ok: 1 call\n=> text, 13 bytes:\nline 2\nline 3"} =
             Code.run(~S|V.output("r1", 2..3)|, context)

    # A one-line string still reads as a value.
    assert {:ok, ~s(ok: 0 calls\n=> "one line")} = Code.run(~S|"one line"|, context)

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

  test "sends the session log each call's whole arguments and value, and the whole output" do
    %{session: id} = context = session()
    Agent.subscribe(id)
    long = String.duplicate("y", 300)

    script =
      ~s|V.write("lib/long.txt", "#{long}")\n| <>
        ~S|IO.puts(String.duplicate("z", 10_000)); V.read("lib/app.ex")|

    assert {:ok, summary} = Code.run(script, context)

    assert_receive {:agent,
                    {:code_call, "c1", %{n: 1, status: :ok, args: ["lib/long.txt", ^long]}}}

    assert_receive {:agent,
                    {:code_call, "c1", %{n: 2, status: :ok, returned: "defmodule App do" <> _}}}

    assert_receive {:agent, {:script_end, "c1", %{status: :ok, stdio: stdio, value: value}}}
    assert stdio == String.duplicate("z", 10_000) <> "\n"
    assert value =~ "defmodule App do"
    # The model still sees the value, and the printed output cut.
    assert summary =~ ~r/=> text, [\d,]+ bytes:\ndefmodule App do/
    assert summary =~ "[cut at"

    assert {:error, _message} = Code.run(~S|V.ls("lib"); {:ok, _} = :error|, context)
    assert_receive {:agent, {:script_end, "c1", %{status: :error, message: message}}}
    assert message =~ "MatchError"
  end
end
