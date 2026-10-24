defmodule Visor.WorkspaceRulesTest do
  # Visor.Workspace's rules over a few thousand generated paths (see
  # Visor.PathCases). A failure names its seed: set VISOR_PATH_SEED to it
  # to run the same paths again.
  use ExUnit.Case, async: false

  alias Visor.{PathCases, Workspace}

  @moduletag :tmp_dir
  @count 3_000

  setup %{tmp_dir: tmp_dir} do
    root = PathCases.fixture(tmp_dir)
    previous = Application.get_env(:visor, :workspace)
    Application.put_env(:visor, :workspace, root)
    on_exit(fn -> Application.put_env(:visor, :workspace, previous) end)

    seed =
      case System.get_env("VISOR_PATH_SEED") do
        nil -> ExUnit.configuration()[:seed]
        seed -> String.to_integer(seed)
      end

    {:ok, real_root} = PathCases.real(root)
    %{root: root, real_root: real_root, seed: seed}
  end

  defp under?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp secret?(path), do: Workspace.secret?(Path.basename(path))

  test "never resolves a path that leads outside the project", ctx do
    for path <- PathCases.paths(ctx.seed, @count, ctx.root),
        {:ok, full} <- [Workspace.resolve(path)] do
      assert under?(full, ctx.root), "seed #{ctx.seed}: #{inspect(path)} resolved to #{full}"

      assert {:ok, real} = PathCases.real(full),
             "seed #{ctx.seed}: #{inspect(path)} resolved, though its links loop"

      assert under?(real, ctx.real_root),
             "seed #{ctx.seed}: #{inspect(path)} resolved to #{full}, which leads to #{real}"
    end
  end

  test "never lets a tool read or change a secret, or write Visor's own folder", ctx do
    visor = Path.join(ctx.real_root, ".visor")

    for path <- PathCases.paths(ctx.seed, @count, ctx.root),
        {:ok, full} <- [Workspace.resolve(path)],
        {:ok, real} <- [PathCases.real(full)] do
      if Workspace.readable(full, path) == :ok do
        refute secret?(full) or secret?(real), "seed #{ctx.seed}: #{inspect(path)} is readable"
      end

      if Workspace.writable(full, path) == :ok do
        refute secret?(full) or secret?(real), "seed #{ctx.seed}: #{inspect(path)} is writable"

        refute under?(real, visor),
               "seed #{ctx.seed}: #{inspect(path)} is writable, and leads into .visor (#{real})"
      end
    end
  end

  test "generates the shapes it is meant to", ctx do
    paths = PathCases.paths(ctx.seed, @count, ctx.root)
    resolved = Enum.count(paths, &match?({:ok, _}, Workspace.resolve(&1)))

    # Enough of both kinds that the rules are tried either way.
    assert resolved > 300 and resolved < @count - 300
    assert Enum.any?(paths, &String.contains?(&1, "vlink"))
    assert Enum.any?(paths, &String.contains?(&1, "env_link"))
  end
end
