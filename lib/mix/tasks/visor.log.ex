defmodule Mix.Tasks.Visor.Log do
  @shortdoc "Lists session logs, prints one as a timeline, or prints the server log"

  @moduledoc """
  Reads the session logs `Visor.SessionLog` writes.

      mix visor.log              # the latest sessions, what they used and how each ended
      mix visor.log latest       # the latest session as a timeline
      mix visor.log 3fa9c1       # one session by its id
      mix visor.log latest --full
      mix visor.log 3fa9c1 --request 4
      mix visor.log server       # what the latest server start logged
      mix visor.log server 2026-10-21T2201 --level warning

  Long replies, scripts and tool results are cut to a few lines unless
  `--full` is given, which also shows reasoning, status changes, response
  headers, each script's whole output and the full arguments of `V` calls.
  `--request N` prints the request of model call N as it was sent: the
  same content, though not the same key order. The values `V` calls
  returned are only in the JSON lines (`returned`). `--dir` reads logs
  from another directory and `--limit` sets how many sessions the list
  shows (default 15).

  `server` prints a server log (`Visor.ServerLog`): the latest, or the
  one whose start time begins with the given text. `--level` leaves out
  what is less severe, and `--full` shows where each line came from.
  """
  use Mix.Task

  import Visor.Format, only: [count: 2, number: 1]

  @switches [full: :boolean, dir: :string, limit: :integer, request: :integer, level: :string]
  @levels ~w(emergency alert critical error warning notice info debug)

  @usage """
  Usage: mix visor.log [latest | ID] [--full | --request N] [--dir DIR]
         mix visor.log server [latest | START] [--level LEVEL] [--full] [--dir DIR]\
  """
  @preview_chars 700
  @preview_lines 14

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.config")

    case rest do
      ["server" | rest] -> server(rest, opts)
      rest -> sessions(rest, opts)
    end
  end

  defp sessions(rest, opts) do
    dir = opts[:dir] || Visor.SessionLog.dir() || Mix.raise("Session logging is turned off.")
    files = dir |> Path.join("*.jsonl") |> Path.wildcard() |> Enum.sort()

    case rest do
      [] ->
        list(files, dir, opts[:limit] || 15)
        server_hint()

      ["latest"] ->
        show(List.last(files) || Mix.raise("No session logs in #{dir}."), opts)

      [id] ->
        show(find(files, id), opts)

      _ ->
        Mix.raise(@usage)
    end
  end

  defp server(rest, opts) do
    dir = opts[:dir] || Visor.ServerLog.dir() || Mix.raise("The server log is turned off.")
    files = server_files(dir)

    file =
      case rest do
        latest when latest in [[], ["latest"]] ->
          List.last(files) || Mix.raise("No server logs in #{dir}.")

        [start] ->
          Enum.find(Enum.reverse(files), &String.starts_with?(Path.basename(&1), start)) ||
            Mix.raise("No server log started at #{start} in #{dir}.")

        _ ->
          Mix.raise(@usage)
      end

    least = opts[:level] || "debug"
    least in @levels || Mix.raise("--level takes one of: #{Enum.join(@levels, ", ")}")
    Mix.shell().info(Path.relative_to_cwd(file) <> "\n")

    for line <- read(file), severe?(line["level"], least) do
      [head | body] = preview(line["message"] || inspect(line), opts) ++ source(line, opts)
      time = line |> Map.get("at", "") |> String.slice(11, 12)

      Mix.shell().info(
        Enum.join([time, String.pad_trailing(line["level"] || "?", 8), head], "  ")
      )

      Enum.each(body, &Mix.shell().info(String.duplicate(" ", 24) <> &1))
    end
  end

  defp server_files(dir), do: dir |> Path.join("*.jsonl") |> Path.wildcard() |> Enum.sort()

  # A line without a known level, such as one that isn't JSON, is shown.
  defp severe?(level, least) do
    case Enum.find_index(@levels, &(&1 == level)) do
      nil -> true
      n -> n <= Enum.find_index(@levels, &(&1 == least))
    end
  end

  defp source(line, opts) do
    if opts[:full] do
      where = Enum.reject([line["mfa"], file_line(line), line["pid"]], &is_nil/1)
      metadata = if line["metadata"], do: [Jason.encode!(line["metadata"])], else: []
      if(where == [], do: [], else: ["at " <> Enum.join(where, ", ")]) ++ metadata
    else
      []
    end
  end

  defp file_line(%{"file" => file, "line" => line}) when is_integer(line), do: "#{file}:#{line}"
  defp file_line(%{"file" => file}), do: file
  defp file_line(_line), do: nil

  # Under the session list: how to see what the server logged.
  defp server_hint do
    with dir when is_binary(dir) <- Visor.ServerLog.dir(),
         file when is_binary(file) <- List.last(server_files(dir)) do
      counts = file |> read() |> Enum.frequencies_by(& &1["level"])

      problems =
        for level <- ~w(error warning),
            Map.has_key?(counts, level),
            do: count(counts[level], level)

      since = if problems == [], do: "nothing wrong", else: Enum.join(problems, ", ")
      Mix.shell().info("\nServer log since the last start: #{since} (mix visor.log server)")
    end
  end

  defp show(file, opts) do
    if turn = opts[:request],
      do: Mix.shell().info(Jason.encode!(request(read(file), turn), pretty: true)),
      else: timeline(file, opts)
  end

  # A request put back together: its own line has the messages the one
  # before it didn't, and the tools when they changed.
  defp request(events, turn) do
    requests = for %{"event" => "request"} = event <- events, do: event

    # After an agent crash, turns count from 1 again; the latest wins.
    last =
      Enum.find_index(Enum.reverse(requests), &(&1["turn"] == turn)) ||
        Mix.raise("No request for model call #{turn} in this log.")

    requests = Enum.take(requests, length(requests) - last)

    messages =
      Enum.reduce(requests, [], fn r, messages ->
        Enum.take(messages, r["messages_from"]) ++ r["messages"]
      end)

    tools =
      requests |> Enum.reverse() |> Enum.find_value(&if(is_list(&1["tools"]), do: &1["tools"]))

    body = Map.put(List.last(requests)["params"], "messages", messages)
    if tools, do: Map.put(body, "tools", tools), else: body
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
      used = used(events)
      took = events |> List.last(%{}) |> Map.get("elapsed_ms")

      Mix.shell().info(
        "#{started}  #{id}  #{count(prompts, "prompt")}, #{count(used["turns"], "turn")}, " <>
          "#{count(used["tool_calls"], "tool call")}, #{number(used["prompt_tokens"])} tokens in, " <>
          "#{number(used["completion_tokens"])} out, #{seconds(took)}  #{ending(events)}"
      )
    end

    Mix.shell().info("\nRead one with: mix visor.log ID, or ID --request N for a request as sent")
  end

  # What a session used, as the log counted it: its summary line, or
  # without one (it is running, or the server stopped) the prompts that
  # ended.
  defp used(events) do
    lines =
      case Enum.filter(events, &(&1["event"] == "summary")) do
        [] -> Enum.filter(events, &(&1["event"] == "prompt_end"))
        summaries -> [List.last(summaries)]
      end

    for field <- ~w(turns tool_calls prompt_tokens completion_tokens), into: %{} do
      {field, Enum.sum(for line <- lines, is_integer(line[field]), do: line[field])}
    end
  end

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

  defp describe(%{"event" => "user"} = e, opts) do
    n = if e["prompt"], do: " #{e["prompt"]}", else: ""
    ["prompt#{n}" | preview(e["text"], opts)]
  end

  defp describe(%{"event" => "turn_start"} = e, _opts) do
    thinking = if e["thinking"], do: "thinking on, effort #{e["effort"]}", else: "thinking off"
    step = if e["step"], do: "step #{e["step"]} of #{e["max_steps"]}, ", else: ""

    [
      "turn #{e["turn"]}  model call with #{count(e["messages"], "message")}, #{step}" <>
        "#{thinking} #{e["pid"]}"
    ]
  end

  defp describe(%{"event" => "request"} = e, _opts) do
    new = e["messages_total"] - e["messages_from"]

    [
      "turn #{e["turn"]}  request POST #{e["url"]}, #{count(e["messages_total"], "message")} " <>
        "(#{number(new)} new), #{number(e["bytes"])} bytes"
    ]
  end

  defp describe(%{"event" => "response", "error" => error} = e, _opts),
    do: ["turn #{e["turn"]}  response: request failed: #{error}"]

  defp describe(%{"event" => "response"} = e, opts) do
    headers =
      if opts[:full],
        do:
          for(
            {name, values} <- e["headers"] || %{},
            do: "#{name}: #{Enum.join(List.wrap(values), ", ")}"
          ),
        else: []

    ["turn #{e["turn"]}  response HTTP #{e["status"]}" | headers ++ preview(e["body"], opts)]
  end

  defp describe(%{"event" => "script_end"} = e, opts) do
    if opts[:full] do
      printed =
        if e["stdio"] not in [nil, ""], do: ["printed:" | preview(e["stdio"], opts)], else: []

      value = if e["value"], do: ["value:" | preview(e["value"], opts)], else: []
      error = if e["message"], do: ["#{e["type"]}:" | preview(e["message"], opts)], else: []
      ["script  #{e["call_id"]} #{e["status"]}, whole output" | printed ++ value ++ error]
    else
      []
    end
  end

  defp describe(%{"event" => "prompt_end"} = e, _opts) do
    ["done    prompt #{e["prompt"]} #{reason(e)} after #{seconds(e["ms"])}", totals(e)]
  end

  defp describe(%{"event" => "summary"} = e, _opts) do
    endings = Enum.map_join(e["endings"] || %{}, ", ", fn {reason, n} -> "#{n} #{reason}" end)

    [
      "summary #{count(e["prompts"], "prompt")} (#{endings}) in #{seconds(e["ms"])}",
      totals(e)
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
    usage = Visor.Usage.from(usage)
    cached = if usage.cached, do: " (#{number(usage.cached)} cached)", else: ""

    head =
      "turn #{e["turn"]}  #{e["finish_reason"]} after #{seconds(e["ms"])} " <>
        "(first token #{seconds(e["ttft_ms"])}), #{number(usage.prompt)} tokens in" <>
        "#{cached}, #{number(usage.completion)} out"

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
    do: ["tool    #{e["name"]} #{e["id"]} started #{e["pid"] || "(cancelled before its turn)"}"]

  defp describe(%{"event" => "tool_end"} = e, opts) do
    ms = if e["ms"], do: " in #{seconds(e["ms"])}", else: ""
    ["tool    #{e["name"]} #{e["id"]} #{e["status"]}#{ms}" | preview(e["result"], opts)]
  end

  defp describe(%{"event" => "code_call"} = e, opts) do
    ms = if e["ms"], do: " #{e["ms"]} ms", else: ""
    error = if e["error"], do: ": #{e["error"]}", else: ""

    # The call's text cuts long arguments; --full shows them whole.
    args =
      if opts[:full],
        do:
          for(
            {arg, i} <- Enum.with_index(e["args"] || [], 1),
            is_binary(arg) and (String.length(arg) > 60 or String.contains?(arg, "\n")),
            line <- ["argument #{i}:" | preview(arg, opts)],
            do: line
          ),
        else: []

    ["  V     #{e["text"]} #{e["status"]}#{ms}#{error}" | args]
  end

  defp describe(%{"event" => "status"} = e, opts),
    do: if(opts[:full], do: ["status  #{e["status"]}"], else: [])

  defp describe(%{"event" => "note"} = e, _opts), do: ["note    #{e["level"]}: #{e["text"]}"]

  defp describe(%{"event" => "settings"} = e, _opts),
    do: ["settings  effort #{e["effort"]}, thinking #{if e["thinking"], do: "on", else: "off"}"]

  defp describe(%{"event" => "context", "messages" => 0}, _opts), do: ["conversation cleared"]
  defp describe(%{"event" => "context"}, _opts), do: []

  defp describe(%{"event" => "steer"} = e, _opts), do: ["steer   #{e["text"]}"]

  defp describe(%{"event" => "compaction"} = e, _opts) do
    [
      "compact  #{count(e["summarized"], "message")} summarized (#{e["reason"]}), " <>
        "about #{number(e["tokens_before"])} → #{number(e["tokens_after"])} tokens"
    ]
  end

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

  defp reason(%{"reason" => "answered"}), do: "answered"
  defp reason(%{"reason" => "step_limit"}), do: "stopped at the limit of model calls"
  defp reason(%{"reason" => "max_tokens"}), do: "cut off at max_tokens"
  defp reason(%{"reason" => "interrupted"}), do: "interrupted"
  defp reason(%{"reason" => "model_error"}), do: "ended by a model error"
  defp reason(%{"reason" => "model_crashed"}), do: "ended by a model call crash"
  defp reason(%{"reason" => "unfinished"}), do: "ended with the model unfinished"
  defp reason(%{"reason" => "agent_crashed"}), do: "ended by an agent crash"
  defp reason(%{"reason" => "session_stopped"}), do: "unfinished when the session stopped"
  defp reason(%{"reason" => "log_stopped"}), do: "unfinished when the server stopped"
  defp reason(%{"reason" => other}), do: "ended: #{other}"

  # What a prompt or a session used.
  defp totals(e) do
    failed = fn n -> if n > 0, do: " (#{number(n)} failed)", else: "" end
    cached = if e["cached_tokens"] > 0, do: " (#{number(e["cached_tokens"])} cached)", else: ""

    reasoning =
      if e["reasoning_tokens"] > 0, do: " (#{number(e["reasoning_tokens"])} reasoning)", else: ""

    "#{count(e["turns"], "model call")}, #{count(e["tool_calls"], "tool call")}" <>
      "#{failed.(e["tool_errors"])}, #{count(e["v_calls"], "V call")}#{failed.(e["v_errors"])}, " <>
      "#{count(e["errors"], "error")}, #{number(e["prompt_tokens"])} tokens in#{cached}, " <>
      "#{number(e["completion_tokens"])} out#{reasoning}, model #{seconds(e["model_ms"])}, " <>
      "tools #{seconds(e["tool_ms"])}, #{number(e["request_bytes"])} bytes sent"
  end

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
end
