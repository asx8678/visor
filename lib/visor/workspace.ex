defmodule Visor.Workspace do
  @moduledoc """
  The project folder the agent works in, and the rules every path a tool
  touches goes through:

    * a path must be inside the folder both as written and once each
      symlink in it is followed, so a link can't lead outside;
    * `.env` files hold the API key, so they can't be read or changed,
      under their own name or a link's. That keeps the key out of tool
      results, and so out of the transcript and the request body.

  Symlinks are followed here rather than by `File`, so a link that loops
  is refused instead of hanging.
  """

  @max_links 40

  @doc "The project folder: `config :visor, workspace: path`, or the current one."
  def root, do: Application.get_env(:visor, :workspace) || File.cwd!()

  @doc "The absolute path for a project path, or an error if it leads outside."
  def resolve(path) do
    root = root()
    full = Path.expand(path, root)

    if inside?(full, root),
      do: {:ok, full},
      else: {:error, "#{path} is outside the project folder."}
  end

  @doc "Whether `full` is in `root` both as written and with its symlinks followed."
  def inside?(full, root), do: under?(full, root) and real_under?(full, root)

  @doc "Whether `full`, with its symlinks followed, is in `root`."
  def real_under?(full, root) do
    case {real(root), real(full)} do
      {{:ok, real_root}, {:ok, real}} -> under?(real, real_root)
      _loop -> false
    end
  end

  @doc "`:ok` if a tool may read `full`, which the model named `path`."
  def readable(full, path) do
    if secret_file?(full),
      do: {:error, "#{path} holds secrets and can't be read."},
      else: :ok
  end

  @doc "`:ok` if a tool may change `full`, which the model named `path`."
  def writable(full, path) do
    if secret_file?(full),
      do: {:error, "#{path} holds secrets and can't be changed."},
      else: :ok
  end

  @doc "Whether `full` is a secrets file, under its own name or the one a link leads to."
  def secret_file?(full) do
    case real(full) do
      {:ok, real} -> secret?(Path.basename(full)) or secret?(Path.basename(real))
      :loop -> secret?(Path.basename(full))
    end
  end

  @doc "Whether a file name is a secrets file's."
  def secret?(name), do: name == ".env" or String.starts_with?(name, ".env.")

  defp under?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  # The path the OS opens for `full`: each symlink in it followed, as far
  # as it exists. `:loop` for a link that leads back to itself.
  defp real(full) do
    [top | parts] = Path.split(full)
    follow(parts, top, 0)
  end

  defp follow(_parts, _path, links) when links > @max_links, do: :loop
  defp follow([], path, _links), do: {:ok, path}
  defp follow(["." | parts], path, links), do: follow(parts, path, links)
  defp follow([".." | parts], path, links), do: follow(parts, Path.dirname(path), links)

  defp follow([part | parts], path, links) do
    next = Path.join(path, part)

    case File.read_link(next) do
      # A relative target starts from the link's folder.
      {:ok, target} ->
        case Path.split(target) do
          ["/" | target] -> follow(target ++ parts, "/", links + 1)
          target -> follow(target ++ parts, path, links + 1)
        end

      {:error, _not_a_link} ->
        follow(parts, next, links)
    end
  end
end
