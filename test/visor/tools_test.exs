defmodule Visor.ToolsTest do
  use ExUnit.Case, async: false

  alias Visor.Tools

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:visor, :workspace)
    Application.put_env(:visor, :workspace, tmp_dir)
    on_exit(fn -> Application.put_env(:visor, :workspace, previous) end)

    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.write!(Path.join(tmp_dir, "lib/app.ex"), "defmodule App do\n  use Supervisor\nend\n")
    :ok
  end

  test "lists a folder, marking subfolders" do
    assert {:ok, ["lib/"]} = Tools.list(".")
  end

  test "reads files inside the workspace only" do
    assert {:ok, "defmodule App do" <> _} = Tools.read("lib/app.ex")
    assert {:error, "../outside is outside the project folder."} = Tools.read("../outside")
    assert {:error, "missing.ex does not exist."} = Tools.read("missing.ex")
  end

  test "keeps .env out of reads and searches", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, ".env"), "DEEPSEEK_API_KEY=Supervisor\n")

    assert {:error, ".env holds secrets and can't be read."} = Tools.read(".env")

    assert {:ok, [%{file: "lib/app.ex", line: 2, text: "use Supervisor"}]} =
             Tools.search("Supervisor", ".")

    # Named, under its own name or a link's.
    File.ln_s!(".env", Path.join(tmp_dir, "notes.txt"))

    for path <- [".env", "notes.txt"] do
      assert {:error, "#{path} holds secrets and can't be read."} ==
               Tools.search("Supervisor", path)
    end
  end

  test "keeps the API key out of shell commands' environment" do
    previous = System.get_env("DEEPSEEK_API_KEY")
    System.put_env("DEEPSEEK_API_KEY", "secret")
    on_exit(fn -> if previous, do: System.put_env("DEEPSEEK_API_KEY", previous) end)
    on_exit(fn -> unless previous, do: System.delete_env("DEEPSEEK_API_KEY") end)

    assert {0, "unset\n"} = Tools.shell("echo ${DEEPSEEK_API_KEY:-unset}")
  end

  test "stops what a command started when it returns, times out or its caller dies" do
    assert {0, _} = Tools.shell("sleep 30 >/dev/null 2>&1 & echo $! > left")
    assert {0, _} = Tools.shell(gone("left"), timeout: 5_000)

    assert {:timeout, _} = Tools.shell("sleep 30 & echo $! > timed; wait", timeout: 300)
    assert {0, _} = Tools.shell(gone("timed"), timeout: 5_000)

    caller = spawn(fn -> Tools.shell("sleep 30 & echo $! > orphan; wait") end)
    ref = Process.monitor(caller)
    assert {0, _} = Tools.shell("while [ ! -s orphan ]; do sleep 0.05; done", timeout: 5_000)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
    assert {0, _} = Tools.shell(gone("orphan"), timeout: 5_000)
  end

  # The processes are found by the command's tag in /proc, so on Linux only.
  if File.exists?("/proc/self/environ") do
    test "stops what a command started even when it left the process group" do
      assert {0, _} =
               Tools.shell("setsid sleep 30 >/dev/null 2>&1 </dev/null & echo $! > escaped")

      assert {0, _} = Tools.shell(gone("escaped"), timeout: 5_000)

      # A command under it with a tag of its own (a Visor's command in a
      # check, say) adds to the tag, so stopping the outer one reaches it.
      nested =
        ~S|VISOR_RUN="$VISOR_RUN:inner" sh -c 'setsid sleep 30 >/dev/null 2>&1 </dev/null | <>
          ~S|& echo $! > nested; wait'|

      assert {:timeout, _} = Tools.shell(nested, timeout: 500)
      assert {0, _} = Tools.shell(gone("nested"), timeout: 5_000)
    end
  end

  # A command that waits until the process whose pid is in `file` has
  # exited (a zombie counts as exited).
  defp gone(file),
    do: "while ps -o stat= -p $(cat #{file}) | grep -qv Z; do sleep 0.05; done"

  test "searches with file and line numbers" do
    assert {:ok, [%{file: "lib/app.ex", line: 2}]} = Tools.search("Supervisor", ".")
    assert {:ok, []} = Tools.search("nothing_here", ".")
  end

  test "runs shell commands in the workspace" do
    assert {0, "app.ex\n"} = Tools.shell("ls lib")
    assert {3, "oops\n"} = Tools.shell("echo oops; exit 3")
  end

  test "reads arguments the way they were meant when that is clear" do
    for arguments <- [
          ~s({"code": ["x = 20", "x + 22"]}),
          ~s({"code": "```elixir\\nx = 20\\nx + 22\\n```"}),
          ~s({"script": "x = 20; x + 22"})
        ] do
      assert {:ok, "ok: 0 calls\n=> 42"} = Tools.run("elixir", arguments), arguments
    end

    id = "tools-test-#{System.unique_integer([:positive])}"
    Visor.Agent.subscribe(id)
    Tools.run("elixir", ~s({"code": ["1"]}), %{session: id, call_id: "c9"})

    assert_received {:agent,
                     {:repair,
                      %{reason: :arguments, call_id: "c9", fixes: ["code was a list of lines"]}}}

    # Anything less clear gets its error.
    assert {:error, "The elixir tool needs code" <> _} =
             Tools.run("elixir", ~s({"script": "1", "source": "2"}))
  end

  test "offers one tool, elixir, and returns errors the model can act on" do
    assert [%{function: %{name: "elixir", description: description}}] = Tools.definitions()
    assert description =~ "up to 2,000 V calls"
    assert description =~ "(up to 2 MB)"

    assert {:ok, "ok: 1 call\n=> [\"lib/\"]"} = Tools.run("elixir", ~s|{"code": "V.ls()"}|)
    assert {:error, ~s({"INVALID_JSON":"{nope"})} = Tools.run("elixir", "{nope")
    assert {:error, "The elixir tool needs code" <> _} = Tools.run("elixir", "{}")
    assert {:error, "Unknown tool read_file. Use elixir."} = Tools.run("read_file", "{}")
  end

  test "follows symlinks before deciding a path is in the project", %{tmp_dir: tmp_dir} do
    outside = tmp_dir <> "-outside"
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)
    File.write!(Path.join(outside, "secret.txt"), "Supervisor outside\n")
    File.write!(Path.join(tmp_dir, ".env"), "DEEPSEEK_API_KEY=Supervisor\n")

    File.ln_s!(outside, Path.join(tmp_dir, "out"))
    File.ln_s!("../..", Path.join(tmp_dir, "lib/up"))
    File.ln_s!(".env", Path.join(tmp_dir, "notes.txt"))
    File.ln_s!("lib", Path.join(tmp_dir, "code"))
    File.ln_s!("loop", Path.join(tmp_dir, "loop"))

    for path <- ["out/secret.txt", "out", "lib/up/x", "loop"] do
      assert {:error, message} = Tools.read(path)
      assert message == "#{path} is outside the project folder."
    end

    assert {:error, "out is outside the project folder."} = Tools.list("out")
    assert {:error, _outside} = Tools.write("out/new.txt", "x")
    refute File.exists?(Path.join(outside, "new.txt"))
    assert {:error, "out/* is outside the project folder."} = Tools.glob("out/*")

    # A link to .env under another name is still .env.
    assert {:error, "notes.txt holds secrets and can't be read."} =
             Tools.read("notes.txt")

    assert {:error, "notes.txt holds secrets and can't be changed."} =
             Tools.write("notes.txt", "x")

    # Links that stay inside work when named. Globs and searches leave out
    # the ones that don't, and don't go into linked folders, which can loop
    # (lib/up leads back above the project).
    assert {:ok, "defmodule App do" <> _} = Tools.read("code/app.ex")
    assert {:ok, true} = Tools.exists("code/app.ex")
    assert {:ok, ["code/app.ex"]} = Tools.glob("code/*.ex")
    assert {:ok, ["code", "lib", "lib/app.ex"]} = Tools.glob("**/*")
    assert {:ok, [%{file: "lib/app.ex"}]} = Tools.search("Supervisor", ".")
    assert {:ok, [%{file: "code/app.ex"}]} = Tools.search("Supervisor", "code")
  end

  test "works in a project reached through a symlink", %{tmp_dir: tmp_dir} do
    link = tmp_dir <> "-link"
    File.ln_s!(tmp_dir, link)
    on_exit(fn -> File.rm(link) end)
    Application.put_env(:visor, :workspace, link)

    assert {:ok, "defmodule App do" <> _} = Tools.read("lib/app.ex")
    assert {:ok, ["lib/app.ex"]} = Tools.glob("lib/*.ex")
    assert {:error, "../x is outside the project folder."} = Tools.read("../x")
  end
end
