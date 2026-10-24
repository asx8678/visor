defmodule Visor.Model.Demo do
  @moduledoc """
  A scripted stand-in model for the tests (see `config/test.exs`).

  It streams canned reasoning and runs real scripts, so the harness and
  the process view can be tested without network access. It rejects a
  request the real API would reject for its message order (see
  `invalid/1`), with the error the DeepSeek client would return.
  """
  @behaviour Visor.Model

  @count_functions ~S"""
  V.glob("lib/**/*.ex")
  |> Enum.map(fn path -> {path, length(V.grep("^\\s*defp? ", path))} end)
  |> Enum.sort_by(fn {_path, count} -> count end, :desc)
  |> Enum.take(8)
  """

  @impl true
  def info,
    do: %{
      provider: "Demo",
      model: "scripted demo",
      endpoint: nil,
      max_tokens: nil,
      context_window: nil,
      key: :none
    }

  @impl true
  def stream(request, emit) do
    case invalid(request.messages) do
      nil -> answer(request, emit)
      problem -> {:error, "DeepSeek returned HTTP 400. #{problem}"}
    end
  end

  @doc """
  Why the OpenAI-format API would refuse these messages, or nil: each
  assistant message's tool calls must be answered, one tool message per
  call id, before the next user or assistant message, and a tool message
  must answer a call of the assistant message before it.
  """
  def invalid(messages), do: invalid(messages, [], 0)

  # `open` holds the ids of the last assistant message's unanswered calls.
  defp invalid([], [], _index), do: nil

  defp invalid([], open, _index),
    do: "Tool calls #{Enum.join(open, ", ")} have no tool messages answering them."

  defp invalid([%{"role" => "tool", "tool_call_id" => id} | rest], open, index) do
    if id in open,
      do: invalid(rest, List.delete(open, id), index + 1),
      else: "messages[#{index}]: a tool message must answer a tool call before it (#{id})."
  end

  defp invalid([_message | _rest], [_ | _] = open, index) do
    "messages[#{index}]: tool calls #{Enum.join(open, ", ")} must be answered before " <>
      "the next message."
  end

  defp invalid([%{"role" => "assistant", "tool_calls" => [_ | _] = calls} | rest], [], index),
    do: invalid(rest, Enum.map(calls, & &1["id"]), index + 1)

  defp invalid([_message | rest], [], index), do: invalid(rest, [], index + 1)

  defp answer(request, emit) do
    started = now()

    # A prompt that says SLOWREPLY takes 5 s to answer, whatever the
    # demo's delay, so a test can stop the agent mid-call.
    case List.last(request.messages) do
      %{"role" => "user", "content" => text} when is_binary(text) ->
        if text =~ "SLOWREPLY", do: Process.sleep(5_000)

      _other ->
        :ok
    end

    {reasoning, content, calls} =
      if String.starts_with?(Map.get(request, :system, ""), "[Visor review]"),
        do: review(request),
        else: reply(request.messages, Map.get(request, :tool_choice, "auto"))

    state = %{reasoning: "", content: "", tool_calls: [], chunks: 0}
    pause(8)
    first_token_at = now()
    state = type_out(state, :reasoning, reasoning, emit)
    state = type_out(state, :content, content, emit)

    state =
      Enum.reduce(calls, state, fn call, state ->
        pause(6)
        state = %{state | tool_calls: state.tool_calls ++ [call], chunks: state.chunks + 1}
        emit.(state)
        state
      end)

    message = %{"role" => "assistant", "content" => content, "reasoning_content" => reasoning}

    message =
      case calls do
        [] ->
          message

        calls ->
          Map.put(
            message,
            "tool_calls",
            for call <- calls do
              %{
                "id" => call.id,
                "type" => "function",
                "function" => %{"name" => call.name, "arguments" => call.arguments}
              }
            end
          )
      end

    {:ok,
     %{
       message: message,
       tool_calls: calls,
       finish_reason: if(calls == [], do: "stop", else: "tool_calls"),
       usage: nil,
       model: "demo",
       chunks: state.chunks,
       ttft_ms: first_token_at - started,
       ms: now() - started
     }}
  end

  defp reply(messages, tool_choice) do
    case {List.last(messages), tool_choice} do
      {%{"role" => "tool"}, "none"} -> summarize(messages)
      {%{"role" => "tool"}, _auto} -> keep_going(messages)
      {%{"role" => "user", "content" => text}, _} -> respond(text)
    end
  end

  # A reviewer's request (Visor.Reviewer): a message when the digest says
  # PROBLEM, the goal met when it says DONE, and silence otherwise. A
  # digest that says SLOWREVIEW takes 300 ms, whatever the demo's delay,
  # so the agent's next events come while the review runs.
  defp review(%{messages: [%{"content" => digest} | _]} = request) do
    if digest =~ "SLOWREVIEW", do: Process.sleep(300)

    json =
      cond do
        digest =~ "PROBLEM" ->
          ~s({"action": "message", "message": "Look at the PROBLEM first."})

        digest =~ "DONE" and request.system =~ "supervise" ->
          ~s({"action": "stop", "message": "Done."})

        true ->
          ~s({"action": "silent"})
      end

    {"A review.", json, []}
  end

  # "keep going" asks for a task that never finishes: list the files after
  # every result, for as long as the tools are on.
  defp keep_going([%{"content" => first} | _] = messages) do
    if first =~ "keep going",
      do: script("V.ls()", "Not done yet. I'll list the files again."),
      else: summarize(messages)
  end

  defp respond(text) do
    lower = String.downcase(text)

    cond do
      # One script per ">>" line, all in one reply: a batch of tool calls.
      text =~ ~r/^\s*>>/ ->
        calls =
          for code <- String.split(text, ~r/^\s*>>/m, trim: true),
              do: tool_call("elixir", %{code: String.trim(code)})

        {"The user wrote several scripts. I'll run each as its own call.", "", calls}

      # "timeout 300 > script": a script that asks for a longer time limit.
      match = Regex.run(~r/^\s*timeout\s+(\d+)\s*>\s*(.+)$/s, text) ->
        [_, seconds, code] = match

        call(
          "elixir",
          %{code: String.trim(code), timeout: String.to_integer(seconds)},
          "The user wrote a script that needs more time."
        )

      match = Regex.run(~r/^\s*>\s*(.+)$/s, text) ->
        call(
          "elixir",
          %{code: String.trim(List.last(match))},
          "The user wrote an Elixir script. I'll run it in code mode."
        )

      String.contains?(lower, "count functions") ->
        call(
          "elixir",
          %{code: @count_functions},
          "One script can glob the source files and grep each of them, " <>
            "all in a single process."
        )

      String.contains?(lower, ["run the checks", "run the tests"]) ->
        call(
          "elixir",
          %{code: "V.check()"},
          "V.check compiles the project and runs its tests in one call, " <>
            "and reports only the errors and failures."
        )

      match = Regex.run(~r/^\s*\$\s*(.+)$/s, text) ->
        command = String.trim(List.last(match))
        script("V.sh(#{inspect(command)})", "The user typed a shell command. I'll run it.")

      match = Regex.run(~r/read\s+([\w.\/-]+)/i, text) ->
        path = List.last(match)

        script(
          "V.read(#{inspect(path)})",
          "The user wants the contents of #{path}. I'll read it."
        )

      match = Regex.run(~r/(?:search|grep|find)\s+(?:for\s+)?["']?([\w.:-]+)/i, text) ->
        pattern = List.last(match)

        script(
          "V.grep(#{inspect(pattern)})",
          "I should search the project for #{pattern} and show where it appears."
        )

      String.contains?(lower, ["beam", "process", "memory", "runtime"]) ->
        script(
          "V.beam_stats()",
          "This is a question about the runtime. BEAM stats will answer it."
        )

      String.contains?(lower, ["keep going", "list", "files", "folder", "directory", "ls"]) ->
        script("V.ls()", "Listing the project root first gives me the lay of the land.")

      true ->
        {"I have no model behind me, so I can only follow a script.",
         "I'm the scripted demo model, so I can't really answer that. " <>
           "Add DEEPSEEK_API_KEY to .env in the project folder to talk to DeepSeek.\n\n" <>
           "Meanwhile, try: \"list the files\", \"read mix.exs\", \"search for Supervisor\", " <>
           "\"run the checks\", " <>
           "\"show BEAM stats\", \"$ ls lib\" or Elixir code mode, such as " <>
           "\"> V.glob(\"lib/**/*.ex\") |> length()\".", []}
    end
  end

  defp script(code, reasoning), do: call("elixir", %{code: code}, reasoning)

  defp call(name, args, reasoning), do: {reasoning, "", [tool_call(name, args)]}

  defp tool_call(name, args) do
    %{
      id: "demo_#{System.unique_integer([:positive])}",
      name: name,
      arguments: Jason.encode!(args)
    }
  end

  defp summarize(messages) do
    results =
      messages
      |> Enum.reverse()
      |> Enum.take_while(&(&1["role"] == "tool"))
      |> Enum.reverse()
      |> Enum.map_join("\n\n", fn %{"content" => content} -> String.slice(content, 0, 600) end)

    {"The tool results are back. I'll pass along the first part of what they returned.",
     "Here is what came back:\n\n" <> results, []}
  end

  defp type_out(state, _key, "", _emit), do: state

  defp type_out(state, key, text, emit) do
    text
    |> String.split(~r/(?<=\s)/)
    |> Enum.chunk_every(3)
    |> Enum.reduce(state, fn words, state ->
      pause(1)

      state = %{
        state
        | key => Map.fetch!(state, key) <> Enum.join(words),
          chunks: state.chunks + 1
      }

      emit.(state)
      state
    end)
  end

  defp pause(steps), do: Process.sleep(steps * Application.get_env(:visor, :demo_delay_ms, 30))
  defp now, do: System.monotonic_time(:millisecond)
end
