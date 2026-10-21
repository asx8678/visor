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
    assert {:ok, listing} = Tools.run("list_dir", ~s({"path": "."}))
    assert listing == "lib/"
  end

  test "reads files inside the workspace only" do
    assert {:ok, "defmodule App do" <> _} = Tools.run("read_file", ~s({"path": "lib/app.ex"}))

    assert {:error, "../outside is outside the project folder."} =
             Tools.run("read_file", ~s({"path": "../outside"}))

    assert {:error, "missing.ex does not exist."} =
             Tools.run("read_file", ~s({"path": "missing.ex"}))
  end

  test "keeps .env out of read_file and grep", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, ".env"), "DEEPSEEK_API_KEY=Supervisor\n")

    assert {:error, ".env holds secrets and can't be read."} =
             Tools.run("read_file", ~s({"path": ".env"}))

    assert {:ok, "lib/app.ex:2: use Supervisor"} =
             Tools.run("grep", ~s({"pattern": "Supervisor"}))
  end

  test "greps with file and line numbers" do
    assert {:ok, "lib/app.ex:2: use Supervisor"} =
             Tools.run("grep", ~s({"pattern": "Supervisor"}))

    assert {:ok, "No matches for nothing_here."} =
             Tools.run("grep", ~s({"pattern": "nothing_here"}))
  end

  test "runs shell commands in the workspace and reports failures" do
    assert {:ok, "app.ex\n"} = Tools.run("bash", ~s({"command": "ls lib"}))
    assert {:error, output} = Tools.run("bash", ~s({"command": "echo oops; exit 3"}))
    assert output == "oops\n\n[exit status 3]"
  end

  test "returns errors the model can act on" do
    assert {:error, ~s({"INVALID_JSON":"{nope"})} = Tools.run("read_file", "{nope")
    assert {:error, "Missing required argument path."} = Tools.run("read_file", "{}")
    assert {:error, "Unknown tool rm_rf."} = Tools.run("rm_rf", "{}")
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
      assert {:error, message} = Tools.read(path, 1_000_000)
      assert message == "#{path} is outside the project folder."
    end

    assert {:error, "out is outside the project folder."} = Tools.list("out")
    assert {:error, _outside} = Tools.write("out/new.txt", "x")
    refute File.exists?(Path.join(outside, "new.txt"))
    assert {:error, "out/* is outside the project folder."} = Tools.glob("out/*")

    # A link to .env under another name is still .env.
    assert {:error, "notes.txt holds secrets and can't be read."} =
             Tools.read("notes.txt", 1_000_000)

    assert {:error, "notes.txt holds secrets and can't be changed."} =
             Tools.write("notes.txt", "x")

    # Links that stay inside work when named. Globs and searches leave out
    # the ones that don't, and don't go into linked folders, which can loop
    # (lib/up leads back above the project).
    assert {:ok, "defmodule App do" <> _} = Tools.read("code/app.ex", 1_000_000)
    assert {:ok, true} = Tools.exists("code/app.ex")
    assert {:ok, ["code/app.ex"]} = Tools.glob("code/*.ex")
    assert {:ok, ["code", "lib", "lib/app.ex"]} = Tools.glob("**/*")
    assert {:ok, [%{file: "lib/app.ex"}]} = Tools.search("Supervisor", ".", 100)
    assert {:ok, [%{file: "code/app.ex"}]} = Tools.search("Supervisor", "code", 100)
  end

  test "works in a project reached through a symlink", %{tmp_dir: tmp_dir} do
    link = tmp_dir <> "-link"
    File.ln_s!(tmp_dir, link)
    on_exit(fn -> File.rm(link) end)
    Application.put_env(:visor, :workspace, link)

    assert {:ok, "defmodule App do" <> _} = Tools.read("lib/app.ex", 1_000_000)
    assert {:ok, ["lib/app.ex"]} = Tools.glob("lib/*.ex")
    assert {:error, "../x is outside the project folder."} = Tools.read("../x", 1_000_000)
  end
end
