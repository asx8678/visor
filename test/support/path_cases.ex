defmodule Visor.PathCases do
  @moduledoc """
  Generated project paths for testing `Visor.Workspace`'s rules on many
  more cases than anyone writes by hand, after pi-fabric's verified
  policy kernels, with a plain seeded generator instead of a property
  testing library.

  `fixture/1` builds a project with the shapes that have gone wrong
  before: secrets, Visor's own folder, and links that lead outside, to a
  secret, to Visor's folder, up a level or back to themselves.
  `paths/2` makes paths of their names and of `..`, `.`, absolute
  starts and odd components. `real/1` follows a path's links with code of
  its own, so the test doesn't check `Visor.Workspace` against itself.
  """

  @parts ~w(.. . lib app.ex .env .env.local .visor scripts x.json out env_link vlink loop dir_out up deep) ++
           ["", "a b", "~", String.duplicate("x", 255)]

  @doc "A project at `dir`/project, and a folder outside it; returns the project's path."
  def fixture(dir) do
    root = Path.join(dir, "project")
    outside = Path.join(dir, "outside")

    for folder <- [root, outside, Path.join(root, "lib/deep"), Path.join(root, ".visor/scripts")],
        do: File.mkdir_p!(folder)

    File.write!(Path.join(root, "lib/app.ex"), "defmodule App do\nend\n")
    File.write!(Path.join(root, ".env"), "DEEPSEEK_API_KEY=not-a-real-key\n")
    File.write!(Path.join(root, ".env.local"), "X=1\n")
    File.write!(Path.join(root, ".visor/scripts/x.json"), "{}")
    File.write!(Path.join(outside, "x.json"), "{}")

    links = [
      {"out", outside},
      {"env_link", ".env"},
      {"vlink", ".visor"},
      {"loop", "loop"},
      {"dir_out", "/etc"},
      {"lib/up", ".."},
      {"lib/deep/env_link", "../../.env"}
    ]

    for {name, target} <- links, do: File.ln_s!(target, Path.join(root, name))
    root
  end

  @doc "`count` paths from `seed`: relative mostly, some absolute."
  def paths(seed, count, root) do
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 2})
    for _ <- 1..count, do: path(root)
  end

  defp path(root) do
    parts = for _ <- 1..Enum.random(1..6), do: Enum.random(@parts)
    relative = Enum.join(parts, "/")

    case :rand.uniform(10) do
      1 -> "/" <> relative
      2 -> Path.join(root, relative)
      3 -> Path.join([root, "..", relative])
      _ -> relative
    end
  end

  @doc "The path with every link in it followed, or `:loop`."
  def real(path), do: follow(Path.split(path), "/", 0)

  defp follow(_parts, _at, depth) when depth > 40, do: :loop
  defp follow([], at, _depth), do: {:ok, at}
  defp follow(["/" | rest], _at, depth), do: follow(rest, "/", depth)
  defp follow(["." | rest], at, depth), do: follow(rest, at, depth)
  defp follow([".." | rest], at, depth), do: follow(rest, Path.dirname(at), depth)

  defp follow([part | rest], at, depth) do
    next = Path.join(at, part)

    case File.read_link(next) do
      {:ok, target} ->
        target = if Path.type(target) == :absolute, do: target, else: Path.join(at, target)
        follow(Path.split(target) ++ rest, "/", depth + 1)

      {:error, _not_a_link} ->
        follow(rest, next, depth)
    end
  end
end
