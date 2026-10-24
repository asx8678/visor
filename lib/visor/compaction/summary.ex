defmodule Visor.Compaction.Summary do
  @moduledoc """
  The summary a compaction puts in place of the messages before its cut,
  compiled from them without a model, after pi-fabric's deterministic
  compactor. It reads only typed facts: who said what, which scripts ran,
  and what each script's V calls did (`Visor.Code.facts/1`). It never reads
  meaning into a tool's output, and it leaves reasoning out.

  Its sections, each bounded and then bounded together:

    * the last user exchanges in full: what the user asked and what the
      assistant answered, which is not a verified outcome
    * earlier requests, one line each
    * the files the session wrote, changed and read
    * the last check of each scope, and the commands run
    * failures, each marked resolved once the same call later worked
    * where things stood, and the last steps one line each

  Every line names the message or tool call it came from, and
  `V.recall/1` reads a tool result back in full. The same messages and
  facts always give the same text.
  """

  alias Visor.Tools

  @file_calls [:ls, :glob, :read, :exists?, :write, :edit]
  @exchanges 3
  @exchange_bytes 3_968
  @line_bytes 1_024
  @sample 24
  @last_steps 40
  # The section ceilings are for a summary of this size; a smaller limit
  # scales them down together.
  @full_bytes 32_768

  @sections [
    {:dialogue, "[Recent user directions and discussion]", 12_288},
    {:requests, "[Earlier requests]", 4_096},
    {:files, "[Files]", 4_608},
    {:checks, "[Checks]", 2_048},
    {:commands, "[Commands]", 2_048},
    {:failures, "[Failures]", 4_608},
    {:status, "[Where things stood]", 2_048},
    {:steps, "[Last steps]", 5_120}
  ]

  # What goes first when the whole summary is over its limit.
  @drop_order [:steps, :requests, :commands, :checks, :files, :failures, :status, :dialogue]

  @doc """
  The summary of `messages`, at most `limit` bytes. `facts` holds what each
  tool call's script did, by tool call id: `%{status: status, calls: facts}`.
  """
  def compile(messages, facts, limit) do
    events = events(messages, facts)

    sections = %{
      dialogue: dialogue(events),
      requests: requests(events),
      files: files(events),
      checks: checks(events),
      commands: commands(events),
      failures: failures(events),
      status: status(events),
      steps: steps(events)
    }

    header =
      "[Visor compaction] Messages 1-#{length(messages)} of this conversation, compiled " <>
        "without a model. Newer messages below take precedence."

    footer =
      "[A tool result from before this point comes back in full with " <>
        "V.recall(\"<tool call id>\").]"

    render(sections, header, footer, limit)
  end

  ## What happened, as typed events

  defp events(messages, facts) do
    messages
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {message, n} -> message_events(message, n, facts) end)
  end

  defp message_events(%{"role" => "user", "content" => text}, n, _facts), do: [{:user, n, text}]

  defp message_events(%{"role" => "assistant"} = message, n, _facts) do
    text = message["content"] || ""
    said = if String.trim(text) != "", do: [{:assistant, n, text}], else: []
    calls = for call <- message["tool_calls"] || [], do: {:call, n, call["id"], code(call)}
    said ++ calls
  end

  defp message_events(%{"role" => "tool", "tool_call_id" => id, "content" => text}, n, facts) do
    script = Map.get(facts, id, %{})
    status = Map.get(script, :status, :unknown)
    [{:result, n, id, status, first_line(text, 200), Map.get(script, :calls, [])}]
  end

  defp message_events(_message, _n, _facts), do: []

  # The script a call ran, as its first line.
  defp code(%{"function" => %{"arguments" => arguments}}) do
    case Jason.decode(arguments) do
      {:ok, %{"code" => code}} when is_binary(code) -> first_line(code, 120)
      _ -> first_line(arguments, 120)
    end
  end

  defp code(_call), do: ""

  # Each V call a script made, with the tool call it ran under.
  defp v_calls(events) do
    for {:result, _n, id, _status, _headline, calls} <- events, call <- calls, do: {id, call}
  end

  ## Sections

  defp dialogue(events) do
    users = for {:user, _n, _text} = user <- events, do: user

    users
    |> Enum.take(-@exchanges)
    |> Enum.map(fn {:user, n, text} -> exchange(n, text, answer(events, n)) end)
  end

  # The assistant's last words before the user spoke again.
  defp answer(events, n) do
    events
    |> Enum.drop_while(&(elem(&1, 1) <= n))
    |> Enum.take_while(&(elem(&1, 0) != :user))
    |> Enum.filter(&(elem(&1, 0) == :assistant))
    |> List.last()
  end

  defp exchange(n, text, nil),
    do: "User [message #{n}]:\n" <> clip(String.trim(text), @exchange_bytes)

  defp exchange(n, text, {:assistant, m, answer}) do
    answer = String.trim(answer)
    # The user's own words get at least half; a short answer leaves them more.
    user_bytes = max(div(@exchange_bytes, 2), @exchange_bytes - byte_size(answer))
    user = clip(String.trim(text), user_bytes)

    "User [message #{n}]:\n" <>
      user <>
      "\n\nAssistant [message #{m}], not a verified outcome:\n" <>
      clip(answer, @exchange_bytes - byte_size(user))
  end

  defp requests(events) do
    users = for {:user, n, text} <- events, do: "- [message #{n}] " <> first_line(text, 120)
    users |> Enum.drop(-@exchanges) |> sample("earlier requests")
  end

  defp files(events) do
    calls = v_calls(events)

    for {label, name} <- [{"Written", :write}, {"Changed", :edit}, {"Read", :read}],
        paths = paths(calls, name),
        paths != [] do
      {shown, left} = Enum.split(paths, @sample)
      more = if left != [], do: " and #{length(left)} more", else: ""
      "- #{label}: " <> Enum.join(shown, ", ") <> more
    end
  end

  # The paths a kind of call worked on, newest first, each once.
  defp paths(calls, name) do
    for({_id, %{name: ^name, status: :ok, path: path}} <- calls, do: path)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp checks(events) do
    events
    |> v_calls()
    |> Enum.filter(fn {_id, call} -> call.name == :check and Map.has_key?(call, :summary) end)
    |> Enum.reverse()
    |> Enum.uniq_by(fn {_id, call} -> Map.get(call, :path) end)
    |> Enum.reverse()
    |> Enum.map(fn {id, call} -> "- V.#{call.text}: #{call.summary} [call #{id}]" end)
  end

  defp commands(events) do
    events
    |> v_calls()
    |> Enum.filter(fn {_id, call} -> call.name == :sh and Map.has_key?(call, :ran) end)
    |> Enum.map(fn {id, call} -> "- #{call.ran} (exit #{call.exit}) [call #{id}]" end)
    |> Enum.take(-@sample)
  end

  # Each failure once, by what failed: the same V call, command or check
  # scope. One that later worked is marked resolved.
  defp failures(events) do
    calls = v_calls(events) |> Enum.with_index()

    failed =
      for {{id, call}, index} <- calls, key = failure(call), do: {key, index, id, call}

    scripts =
      for {:result, _n, id, :error, headline, script_calls} <- events,
          not Enum.any?(script_calls, &failure/1),
          do: "- script: #{headline} [call #{id}]"

    {open, resolved} =
      failed
      |> Enum.reverse()
      |> Enum.uniq_by(fn {key, _index, _id, _call} -> key end)
      |> Enum.reverse()
      |> Enum.split_with(fn {key, index, _id, _call} -> not resolved?(calls, key, index) end)

    line = fn {_key, _index, id, call} ->
      "- V.#{call.text}: #{failure_text(call)} [call #{id}]"
    end

    Enum.map(open, line) ++
      Enum.take(scripts, -@sample) ++
      Enum.map(Enum.take(resolved, -8), &(line.(&1) <> " RESOLVED"))
  end

  # A file call fails or works for its action and path, as pi-fabric
  # counts them; any other call for its exact text.
  defp failure(%{status: :error, path: path} = call) when call.name in @file_calls,
    do: {:file, call.name, path}

  defp failure(%{status: :error} = call), do: {:call, call.text}
  defp failure(%{name: :sh, exit: exit} = call) when exit != 0, do: {:sh, call.ran}
  defp failure(%{name: :check, check: check} = call) when check != :ok, do: {:check, call[:path]}
  defp failure(_call), do: nil

  defp resolved?(calls, key, index) do
    Enum.any?(calls, fn {{_id, call}, later} -> later > index and worked?(key, call) end)
  end

  defp worked?({:file, name, path}, call),
    do: call.name == name and call[:path] == path and call.status == :ok

  defp worked?({:call, text}, call), do: call.text == text and call.status == :ok
  defp worked?({:sh, ran}, call), do: call[:ran] == ran and call[:exit] == 0

  defp worked?({:check, path}, call),
    do: call.name == :check and call[:path] == path and call[:check] == :ok

  defp failure_text(%{status: :error, error: error}), do: error
  defp failure_text(%{name: :sh, exit: exit}), do: "exit #{exit}"
  defp failure_text(%{summary: summary}), do: summary
  defp failure_text(call), do: to_string(call.status)

  defp status(events) do
    last_user = Enum.find(Enum.reverse(events), &(elem(&1, 0) == :user))
    last_answer = Enum.find(Enum.reverse(events), &(elem(&1, 0) == :assistant))
    last_result = Enum.find(Enum.reverse(events), &(elem(&1, 0) == :result))

    [
      last_user &&
        "- Last request [message #{elem(last_user, 1)}]: " <> first_line(elem(last_user, 2), 140),
      last_answer &&
        "- Last answer [message #{elem(last_answer, 1)}]: " <>
          first_line(elem(last_answer, 2), 140),
      last_result && "- Last step [call #{elem(last_result, 2)}]: " <> elem(last_result, 4)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp steps(events) do
    events
    |> Enum.take(-@last_steps)
    |> Enum.map(fn
      {:user, n, text} ->
        "[#{n}] user: " <> first_line(text, 100)

      {:assistant, n, text} ->
        "[#{n}] assistant: " <> first_line(text, 100)

      {:call, n, id, code} ->
        "[#{n}] script #{id}: " <> clip(code, 80)

      {:result, n, id, _status, headline, _calls} ->
        "[#{n}] result #{id}: " <> clip(headline, 100)
    end)
  end

  ## Rendering, within bounds

  defp render(sections, header, footer, limit) do
    share = min(limit / @full_bytes, 1.0)

    blocks =
      for {key, title, max_bytes} <- @sections, sections[key] != [] do
        # Exchanges read apart; every other section is one line per fact.
        lines = if key == :dialogue, do: separated(sections[key]), else: sections[key]
        {key, block(title, lines, max(floor(max_bytes * share), byte_size(title) + 1))}
      end

    blocks
    |> fit(header, footer, limit, @drop_order)
    |> clip(limit)
  end

  # Whole sections go, least needed first, until the summary fits.
  defp fit(blocks, header, footer, limit, drop_order) do
    text = Enum.join([header | Enum.map(blocks, &elem(&1, 1))] ++ [footer], "\n\n")

    case drop_order do
      [next | rest] when byte_size(text) > limit ->
        fit(List.keydelete(blocks, next, 0), header, footer, limit, rest)

      _fits_or_nothing_left ->
        text
    end
  end

  # A section's lines under its title, the earliest and latest of them when
  # they don't all fit.
  defp block(title, lines, max_bytes) do
    lines = Enum.map(lines, &clip(&1, max(@line_bytes, @exchange_bytes)))
    Enum.find_value(length(lines)..1//-1, title, &sampled_block(title, lines, &1, max_bytes))
  end

  defp sampled_block(title, lines, keep, max_bytes) do
    text = Enum.join([title | sampled(lines, keep)], "\n")
    if byte_size(text) <= max_bytes, do: text
  end

  defp separated([first | rest]), do: [first | Enum.map(rest, &("\n" <> &1))]

  defp sampled(lines, keep) when length(lines) <= keep, do: lines

  defp sampled(lines, keep) do
    earliest = div(keep + 1, 2)
    latest = keep - earliest
    left = length(lines) - keep
    Enum.take(lines, earliest) ++ ["… #{left} left out"] ++ Enum.take(lines, -latest)
  end

  defp sample(lines, noun) do
    case length(lines) - @sample do
      left when left > 0 ->
        Enum.take(lines, div(@sample, 2)) ++
          ["… #{left} #{noun} left out"] ++ Enum.take(lines, -div(@sample, 2))

      _all ->
        lines
    end
  end

  defp first_line(text, max_bytes) do
    text |> String.trim() |> String.split("\n", parts: 2) |> hd() |> clip(max_bytes)
  end

  defp clip(text, max_bytes) when byte_size(text) <= max_bytes, do: text
  defp clip(text, max_bytes), do: Tools.truncate(text, max(max_bytes - 3, 0)) <> "…"
end
