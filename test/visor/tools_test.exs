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
end
