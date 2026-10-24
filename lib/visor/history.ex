defmodule Visor.History do
  @moduledoc """
  What earlier sessions on this project said and did, searched from their
  session logs (`Visor.SessionLog`) for `V.history/2`, after pi-fabric's
  memory recall: ranked hits, each with a ref that `entry/1` reads back
  in full.

  Only typed lines count: the user's prompts, the model's answers, the
  `V` calls scripts made (with how they ended) and scripts that failed.
  Nothing is classified by its words. Only logs whose session ran in this
  project are read, with their sub-agents' logs, the newest
  `Visor.Limits.history_logs/0` of them, and none over
  `Visor.Limits.history_log_bytes/0`. There is no index: each search
  reads the logs again.
  """

  alias Visor.{Limits, SessionLog, Workspace}

  @snippet_chars 300

  @doc """
  Hits for `query` (words, matched case-blind), best first: each
  `%{ref, session, at, kind, text}`, `kind` being `:prompt`, `:answer`,
  `:call` or `:failure`. At most `limit`.
  """
  def search(query, limit \\ 10) do
    terms = query |> String.downcase() |> String.split(~r/\W+/u, trim: true) |> Enum.uniq()

    if terms == [] do
      []
    else
      logs()
      |> Enum.with_index()
      |> Enum.flat_map(fn {{file, session}, age} -> hits(file, session, age, terms) end)
      |> Enum.sort_by(fn hit -> {-hit.score, hit.age, -hit.line} end)
      |> Enum.take(limit)
      |> Enum.map(&Map.drop(&1, [:score, :age, :line]))
    end
  end

  @doc """
  The few hits worth putting before a prompt (`/recall on`, after Vibe's
  context recall): other sessions' prompts and answers that share at
  least two of the prompt's words of four letters or more, and two-fifths
  of them, best first.
  """
  def recall(text, exclude, limit \\ 3) do
    terms =
      text
      |> String.downcase()
      |> String.split(~r/\W+/u, trim: true)
      |> Enum.filter(&(String.length(&1) >= 4))
      |> Enum.uniq()

    needed = max(2, ceil(length(terms) * 0.4))

    logs()
    |> Enum.reject(fn {_file, session} -> session == exclude end)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{file, session}, age} -> hits(file, session, age, terms) end)
    |> Enum.filter(&(&1.kind in [:prompt, :answer] and &1.score >= needed))
    |> Enum.sort_by(fn hit -> {-hit.score, hit.age, -hit.line} end)
    |> Enum.take(limit)
    |> Enum.map(&Map.drop(&1, [:score, :age, :line]))
  end

  @doc "The whole of hit `ref` (`\"SESSION:LINE\"`): `{:ok, text}` or `{:error, message}`."
  def entry(ref) do
    with [session, line] <- String.split(ref, ":", parts: 2),
         {n, ""} <- Integer.parse(line),
         {file, _session} <- Enum.find(logs(), fn {_file, id} -> id == session end),
         %{} = event <- file |> lines() |> Enum.at(n - 1),
         {_kind, text} <- typed(event) do
      {:ok, String.slice(text, 0, 20_000)}
    else
      _ -> {:error, "There is no history entry #{ref} for this project."}
    end
  end

  # This project's logs, newest first, as {file, session id}.
  defp logs do
    case SessionLog.dir() do
      nil ->
        []

      dir ->
        root = Path.expand(Workspace.root())

        files =
          dir
          |> Path.join("*.jsonl")
          |> Path.wildcard()
          |> Enum.sort(:desc)
          |> Enum.reject(&(File.stat!(&1).size > Limits.history_log_bytes()))

        starts = Map.new(files, &{&1, start(&1)})

        ours =
          for {file, %{"workspace" => ^root, "session" => id}} <- starts,
              into: %{},
              do: {id, file}

        files
        |> Enum.filter(fn file ->
          case starts[file] do
            %{"workspace" => ^root} ->
              true

            %{"parent" => parent} when is_binary(parent) ->
              Map.has_key?(ours, hd(String.split(parent, "/")))

            _ ->
              false
          end
        end)
        |> Enum.take(Limits.history_logs())
        |> Enum.map(&{&1, starts[&1]["session"]})
    end
  end

  # A log's first line names its session, its workspace and, for a
  # sub-agent, its parent.
  defp start(file) do
    with [line] <- file |> File.stream!() |> Enum.take(1),
         {:ok, %{"event" => "start"} = event} <- Jason.decode(line) do
      Map.update(event, "workspace", nil, &(&1 && Path.expand(&1)))
    else
      _ -> %{}
    end
  end

  defp lines(file) do
    file
    |> File.stream!()
    |> Enum.map(fn line ->
      case Jason.decode(line) do
        {:ok, event} -> event
        _ -> nil
      end
    end)
  end

  defp hits(file, session, age, terms) do
    file
    |> lines()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {event, n} ->
      with %{} <- event,
           {kind, text} <- typed(event),
           score when score > 0 <- score(text, terms) do
        [
          %{
            ref: "#{session}:#{n}",
            session: session,
            at: event["at"],
            kind: kind,
            text: snippet(text),
            score: score,
            age: age,
            line: n
          }
        ]
      else
        _ -> []
      end
    end)
  end

  # The lines that say something, by their event, never their words.
  defp typed(%{"event" => "user", "text" => text}), do: {:prompt, text}

  defp typed(%{"event" => "turn_end", "finish_reason" => "stop", "content" => text})
       when is_binary(text) and text != "",
       do: {:answer, text}

  defp typed(%{"event" => "code_call", "status" => status, "text" => text} = event)
       when status in ["ok", "error"] do
    error = if event["error"], do: ": " <> event["error"], else: ""
    {:call, "V.#{text} #{status}#{error}"}
  end

  defp typed(%{"event" => "script_end", "status" => "error", "message" => message})
       when is_binary(message),
       do: {:failure, message}

  defp typed(_event), do: nil

  defp score(text, terms) do
    lower = String.downcase(text)
    Enum.count(terms, &String.contains?(lower, &1))
  end

  defp snippet(text) do
    text = String.replace(text, ~r/\s+/, " ")

    if String.length(text) > @snippet_chars,
      do: String.slice(text, 0, @snippet_chars) <> "…",
      else: text
  end
end
