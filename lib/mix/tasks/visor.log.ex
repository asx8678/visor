defmodule Mix.Tasks.Visor.Log do
  @shortdoc "Lists session logs or prints one as a timeline"

  @moduledoc """
  Reads the session logs `Visor.SessionLog` writes.

      mix visor.log              # the latest sessions and how each ended
      mix visor.log latest       # the latest session as a timeline
      mix visor.log 3fa9c1       # one session by its id
      mix visor.log latest --full

  Long replies, scripts and tool results are cut to a few lines unless
  `--full` is given. `--dir` reads logs from another directory and
  `--limit` sets how many sessions the list shows (default 15).
  """
  use Mix.Task

  @switches [full: :boolean, dir: :string, limit: :integer]
  @preview_chars 700
  @preview_lines 14

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.config")

    dir = opts[:dir] || Visor.SessionLog.dir() || Mix.raise("Session logging is turned off.")
    files = dir |> Path.join("*.jsonl") |> Path.wildcard() |> Enum.sort()

    case rest do
      [] -> list(files, dir, opts[:limit] || 15)
      ["latest"] -> timeline(List.last(files) || Mix.raise("No session logs in #{dir}."), opts)
      [id] -> timeline(find(files, id), opts)
      _ -> Mix.raise("Usage: mix visor.log [latest | ID] [--full] [--dir DIR] [--limit N]")
    end
  end

  defp find(files, id) do
    Enum.find(files, &String.ends_with?(&1, "-#{id}.jsonl")) ||
      Mix.raise("No session log for #{id}.")
  end

  defp list([], dir, _limit), do: Mix.shell().info("No session logs in #{dir}.")

  defp list(files, dir, limit) do
    Mix.shell().info("Sessions in #{Path.relative_to_cwd(dir)}, newest last:\n")

    for file <- Enum.take(files, -limit) do
      events = read(file)
      id = file |> Path.basename(".jsonl") |> String.split("-") |> List.last()
      started = events |> List.first(%{}) |> Map.get("at", "?") |> String.slice(0, 19)
      prompts = Enum.count(events, &(&1["event"] == "user"))
      turns = Enum.count(events, &(&1["event"] == "turn_start"))
      tools = Enum.count(events, &(&1["event"] == "tool_start"))

      Mix.shell().info(
        "#{started}  #{id}  #{count(prompts, "prompt")}, #{count(turns, "turn")}, " <>
          "#{count(tools, "tool call")}  #{ending(events)}"
      )
    end

    Mix.shell().info("\nRead one with: mix visor.log ID")
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  # How a session ended, from its last lines.
  defp ending(events) do
    names = MapSet.new(events, & &1["event"])
    owner_down = Enum.find(events, &(&1["event"] == "owner_down"))

    cond do
      owner_down && owner_down["status"] != "idle" ->
        "page closed or reloaded while #{owner_down["status"]}"

      MapSet.member?(names, "agent_down") ->
        "agent crashed"

      MapSet.member?(names, "stall") and not MapSet.member?(names, "stop") ->
        "stalled"

      owner_down ->
        "page closed"

      MapSet.member?(names, "stop") or MapSet.member?(names, "log_stop") ->
        "stopped"

      true ->
        "running, or the server stopped"
    end
  end

  defp timeline(file, opts) do
    events = read(file)
    Mix.shell().info(Path.relative_to_cwd(file) <> "\n")

    # A script call is reported running and then finished; show only the
    # last report of each.
    finished =
      for %{"event" => "code_call", "status" => status} = event <- events,
          status != "running",
          into: MapSet.new(),
          do: {event["call_id"], event["n"]}

    for event <- events,
        not (event["event"] == "code_call" and event["status"] == "running" and
               MapSet.member?(finished, {event["call_id"], event["n"]})),
        # Events with nothing to show describe to [] and are skipped.
        [head | body] <- [describe(event, opts)] do
      time = event |> Map.get("at", "") |> String.slice(11, 8)
      offset = "+" <> seconds(event["elapsed_ms"])
      Mix.shell().info(Enum.join([time, String.pad_leading(offset, 8), head], "  "))
      Enum.each(body, &Mix.shell().info(indent(&1)))
    end
  end

  defp read(file) do
    file
    |> File.stream!()
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, event} -> [event]
        {:error, _} -> [%{"event" => "unreadable", "line" => line}]
      end
    end)
  end

  defp describe(%{"event" => "start"} = e, _opts) do
    ["session #{e["session"]} started, #{e["provider"]} #{e["model"]}, in #{e["workspace"]}"]
  end

  defp describe(%{"event" => "user"} = e, opts), do: ["prompt" | preview(e["text"], opts)]

  defp describe(%{"event" => "turn_start"} = e, _opts) do
    thinking = if e["thinking"], do: "thinking on, effort #{e["effort"]}", else: "thinking off"

    [
      "turn #{e["turn"]}  model call with #{count(e["messages"], "message")}, #{thinking} " <>
        "#{e["pid"]}"
    ]
  end

  defp describe(%{"event" => "stream"} = e, _opts) do
    tools =
      for call <- e["tool_calls"] || [],
          do: ", #{call["name"]} call #{number(call["argument_chars"])} chars"

    [
      "turn #{e["turn"]}  streaming: #{number(e["chunks"])} chunks, " <>
        "#{number(e["reasoning_chars"])} chars reasoning, " <>
        "#{number(e["content_chars"])} chars reply#{tools}"
    ]
  end

  defp describe(%{"event" => "turn_end", "usage" => usage} = e, opts) when is_map(usage) do
    cached = usage["prompt_cache_hit_tokens"]
    cached = if is_integer(cached), do: " (#{number(cached)} cached)", else: ""

    head =
      "turn #{e["turn"]}  #{e["finish_reason"]} after #{seconds(e["ms"])} " <>
        "(first token #{seconds(e["ttft_ms"])}), #{number(usage["prompt_tokens"])} tokens in" <>
        "#{cached}, #{number(usage["completion_tokens"])} out"

    reasoning =
      if opts[:full] && e["reasoning"] not in [nil, ""],
        do: ["reasoning:" | preview(e["reasoning"], opts)],
        else: []

    reply =
      if e["content"] not in [nil, ""], do: ["reply:" | preview(e["content"], opts)], else: []

    calls =
      Enum.flat_map(e["tool_calls"] || [], fn call ->
        ["calls #{call["name"]} #{call["id"]}" | preview(arguments(call["arguments"]), opts)]
      end)

    [head | reasoning ++ reply ++ calls]
  end

  defp describe(%{"event" => "turn_end"} = e, _opts),
    do: ["turn #{e["turn"]}  #{e["finish_reason"]}"]

  defp describe(%{"event" => "tool_start"} = e, _opts),
    do: ["tool    #{e["name"]} #{e["id"]} started #{e["pid"]}"]

  defp describe(%{"event" => "tool_end"} = e, opts) do
    ms = if e["ms"], do: " in #{seconds(e["ms"])}", else: ""
    ["tool    #{e["name"]} #{e["id"]} #{e["status"]}#{ms}" | preview(e["result"], opts)]
  end

  defp describe(%{"event" => "code_call"} = e, _opts) do
    ms = if e["ms"], do: " #{e["ms"]} ms", else: ""
    error = if e["error"], do: ": #{e["error"]}", else: ""
    ["  V     #{e["text"]} #{e["status"]}#{ms}#{error}"]
  end

  defp describe(%{"event" => "status"} = e, opts),
    do: if(opts[:full], do: ["status  #{e["status"]}"], else: [])

  defp describe(%{"event" => "note"} = e, _opts), do: ["note    #{e["level"]}: #{e["text"]}"]

  defp describe(%{"event" => "settings"} = e, _opts),
    do: ["settings  effort #{e["effort"]}, thinking #{if e["thinking"], do: "on", else: "off"}"]

  defp describe(%{"event" => "context", "messages" => 0}, _opts), do: ["conversation cleared"]
  defp describe(%{"event" => "context"}, _opts), do: []

  defp describe(%{"event" => "owner_down"} = e, _opts) do
    running = if e["running"] not in [nil, []], do: [running(e["running"])], else: []
    ["PAGE    #{e["text"]} (#{e["reason"]})" | running]
  end

  defp describe(%{"event" => "agent_down"} = e, _opts) do
    ["CRASH   #{e["text"]}", "reason: #{e["reason"]}"]
  end

  defp describe(%{"event" => "stall"} = e, _opts) do
    processes =
      Enum.flat_map(e["processes"] || [], fn p ->
        head =
          if p["alive"] == false,
            do: "#{p["label"]} #{p["pid"]}: gone",
            else: "#{p["label"]} #{p["pid"]}: #{p["status"]}, #{p["message_queue_len"]} queued"

        [head | Enum.map(Enum.take(p["stacktrace"] || [], 8), &("    " <> &1))]
      end)

    ["STALL   #{e["text"]}" | processes]
  end

  defp describe(%{"event" => "stop"} = e, _opts), do: ["stop    session stopped (#{e["reason"]})"]
  defp describe(%{"event" => "log_stop"} = e, _opts), do: ["log stopped (#{e["reason"]})"]
  defp describe(e, _opts), do: ["#{e["event"]}  #{inspect(Map.drop(e, ["at", "ms", "event"]))}"]

  defp running(labels), do: "running: " <> Enum.join(labels, ", ")

  # Tool arguments are a JSON string; a script reads better as its code.
  defp arguments(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"code" => code}} when is_binary(code) -> code
      _ -> text
    end
  end

  defp arguments(other), do: inspect(other)

  defp preview(nil, _opts), do: []

  defp preview(text, opts) when is_binary(text) do
    lines = String.split(text, "\n")

    if opts[:full] do
      lines
    else
      shown =
        lines |> Enum.take(@preview_lines) |> Enum.join("\n") |> String.slice(0, @preview_chars)

      cut = String.length(text) - String.length(shown)
      more = if cut > 0, do: ["… #{number(cut)} more chars (--full shows all)"], else: []
      String.split(shown, "\n") ++ more
    end
  end

  defp preview(other, opts), do: preview(inspect(other, pretty: true), opts)

  defp indent(line), do: String.duplicate(" ", 20) <> line

  defp seconds(nil), do: "?"
  defp seconds(ms) when ms < 10_000, do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"
  defp seconds(ms), do: "#{round(ms / 1000)}s"

  defp number(nil), do: "?"

  defp number(n) when is_integer(n) do
    n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+$)/, ",")
  end

  defp number(n), do: to_string(n)
end
