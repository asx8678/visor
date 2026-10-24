defmodule Visor.Scripts do
  @moduledoc """
  Saved scripts: `elixir` tool scripts kept under a name in the project's
  `.visor/scripts/`, to run again with `V.run/2` or the console's `/run`.
  After pi-fabric's saved programs.

  Each is one JSON file with its code, a description and the SHA-256 of
  its code. A file whose code no longer matches its digest, such as one
  edited by hand, is refused. Scripts write the folder only through
  `V.save/3`: `Visor.Workspace` keeps the tools out of it.
  """

  alias Visor.{Limits, Workspace}

  @name ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/

  @doc "The folder saved scripts live in."
  def dir, do: Path.join([Workspace.root(), ".visor", "scripts"])

  @doc "Saves `code` as `name`. Returns `{:ok, script}` or `{:error, message}`."
  def save(name, code, description \\ "") do
    cond do
      not Regex.match?(@name, name) ->
        {:error,
         "A script's name is 1 to 64 lowercase letters, digits, dots, dashes and " <>
           "underscores, starting with a letter or digit, not #{inspect(name)}."}

      String.trim(code) == "" ->
        {:error, "A saved script needs code."}

      String.length(code) > Limits.script_chars() ->
        {:error, "A saved script is at most #{Limits.script_chars()} characters."}

      true ->
        script = %{
          name: name,
          code: code,
          description: description,
          digest: digest(code),
          saved_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        }

        File.mkdir_p!(dir())
        File.write!(path(name), Jason.encode_to_iodata!(script, pretty: true))
        {:ok, script}
    end
  end

  @doc "Saved script `name`: `{:ok, script}` or `{:error, message}`."
  def get(name) do
    with true <- Regex.match?(@name, name) || {:error, "There is no saved script #{name}."},
         {:ok, json} <- read(name),
         {:ok, %{"code" => code, "digest" => digest} = script} <- Jason.decode(json) do
      if digest(code) == digest,
        do: {:ok, atomize(script)},
        else: {:error, "Saved script #{name} doesn't match its digest; it was changed by hand."}
    else
      {:error, %Jason.DecodeError{}} -> {:error, "Saved script #{name} isn't valid JSON."}
      {:ok, _other} -> {:error, "Saved script #{name} has no code or digest."}
      {:error, _message} = error -> error
    end
  end

  @doc "The saved scripts, by name, without their code."
  def list do
    case File.ls(dir()) do
      {:ok, files} ->
        for file <- Enum.sort(files),
            String.ends_with?(file, ".json"),
            {:ok, script} <- [get(Path.rootname(file))],
            do: Map.delete(script, :code)

      {:error, _reason} ->
        []
    end
  end

  defp read(name) do
    case File.read(path(name)) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, "There is no saved script #{name}."}
    end
  end

  defp atomize(script) do
    %{
      name: script["name"],
      code: script["code"],
      description: script["description"] || "",
      digest: script["digest"],
      saved_at: script["saved_at"]
    }
  end

  defp path(name), do: Path.join(dir(), name <> ".json")

  defp digest(code), do: :crypto.hash(:sha256, code) |> Base.encode16(case: :lower)
end
