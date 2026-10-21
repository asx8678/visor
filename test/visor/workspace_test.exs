defmodule Visor.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Visor.Workspace

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:visor, :workspace)
    Application.put_env(:visor, :workspace, tmp_dir)
    on_exit(fn -> Application.put_env(:visor, :workspace, previous) end)
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    :ok
  end

  test "resolves paths in the project and refuses the rest", %{tmp_dir: tmp_dir} do
    assert {:ok, full} = Workspace.resolve("lib/app.ex")
    assert full == Path.join(tmp_dir, "lib/app.ex")
    assert {:ok, ^tmp_dir} = Workspace.resolve(".")
    assert {:error, "../x is outside the project folder."} = Workspace.resolve("../x")
    assert {:error, _outside} = Workspace.resolve("/etc/passwd")
  end

  test "refuses a symlink out of the project, and one that loops", %{tmp_dir: tmp_dir} do
    File.ln_s!("/tmp", Path.join(tmp_dir, "out"))
    File.ln_s!("loop", Path.join(tmp_dir, "loop"))
    File.ln_s!("lib", Path.join(tmp_dir, "code"))

    assert {:error, _outside} = Workspace.resolve("out/x")
    assert {:error, _loops} = Workspace.resolve("loop")
    assert {:ok, _inside} = Workspace.resolve("code/app.ex")
  end

  test "treats .env files as secrets, under any name a link gives them", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, ".env"), "KEY=x\n")
    File.ln_s!(".env", Path.join(tmp_dir, "notes.txt"))

    assert Workspace.secret?(".env")
    assert Workspace.secret?(".env.local")
    refute Workspace.secret?("env.ex")

    for name <- [".env", "notes.txt"] do
      full = Path.join(tmp_dir, name)

      assert {:error, "#{name} holds secrets and can't be read."} ==
               Workspace.readable(full, name)

      assert {:error, "#{name} holds secrets and can't be changed."} ==
               Workspace.writable(full, name)
    end

    assert :ok = Workspace.readable(Path.join(tmp_dir, "lib/app.ex"), "lib/app.ex")
  end
end
