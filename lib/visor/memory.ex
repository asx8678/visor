defmodule Visor.Memory do
  @moduledoc """
  What earlier sessions on a project asked to remember, after Vibe's
  curated memory: short notes the model keeps with `V.remember/1`, in the
  project's `.visor/memory.md`, and reads in every later session's system
  prompt (with the project's AGENTS.md, see `Visor.Agent`). Tools can't
  write `.visor/`, so only these functions change it, one session at a
  time (`Visor.Lock`).

  At most `Visor.Limits.memory_items/0` notes of `memory_chars/0` each:
  what doesn't belong in every session's prompt belongs in a file.
  """

  alias Visor.{Limits, Lock, Workspace}

  @doc "The notes, oldest first."
  def list do
    case File.read(path()) do
      {:ok, text} -> for "- " <> note <- String.split(text, "\n"), note != "", do: note
      {:error, _none} -> []
    end
  end

  @doc "Adds a note; one already there is kept once. Returns the notes."
  def remember(note) when is_binary(note) do
    note = note |> String.replace(~r/\s+/, " ") |> String.trim()

    change(fn notes ->
      cond do
        note in notes ->
          {:ok, notes}

        note == "" ->
          {:error, "A note can't be empty."}

        String.length(note) > Limits.memory_chars() ->
          {:error, "A note is at most #{Limits.memory_chars()} characters."}

        length(notes) >= Limits.memory_items() ->
          {:error,
           "The project keeps at most #{Limits.memory_items()} notes. Forget one first, with V.forget(note)."}

        true ->
          {:ok, notes ++ [note]}
      end
    end)
  end

  @doc "Removes a note, by its text. Returns the notes."
  def forget(note) when is_binary(note) do
    change(fn notes ->
      if note in notes,
        do: {:ok, List.delete(notes, note)},
        else: {:error, "There is no note #{inspect(note)}; V.memories() lists them."}
    end)
  end

  @doc "The notes for a system prompt, or an empty string."
  def prompt_text do
    case list() do
      [] ->
        ""

      notes ->
        "\n\nWhat earlier sessions on this project asked to remember (V.remember):\n" <>
          Enum.map_join(notes, "\n", &("- " <> &1))
    end
  end

  defp change(fun) do
    Lock.hold({:file, path()}, fn ->
      with {:ok, notes} <- fun.(list()) do
        File.mkdir_p!(Path.dirname(path()))
        File.write!(path(), Enum.map_join(notes, "", &("- " <> &1 <> "\n")))
        {:ok, notes}
      end
    end)
  end

  defp path, do: Path.join(Workspace.root(), ".visor/memory.md")
end
