defmodule Visor.Model.Demo do
  @moduledoc """
  A scripted stand-in model for the tests (see `config/test.exs`).

  It streams canned reasoning and calls the real tools, so the harness and
  the process view can be tested without network access.
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
    do: %{provider: "Demo", model: "scripted demo", endpoint: nil, max_tokens: nil, key: :none}

  @impl true
  def stream(request, emit) do
    started = now()
    {reasoning, content, calls} = script(request.messages)

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

  defp script(messages) do
    case List.last(messages) do
      %{"role" => "tool"} -> summarize(messages)
      %{"role" => "user", "content" => text} -> respond(text)
    end
  end

  defp respond(text) do
    lower = String.downcase(text)

    cond do
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

        call(
          "bash",
          %{command: command},
          "The user typed a shell command. I'll run it with bash."
        )

      match = Regex.run(~r/read\s+([\w.\/-]+)/i, text) ->
        path = List.last(match)
        call("read_file", %{path: path}, "The user wants the contents of #{path}. I'll read it.")

      match = Regex.run(~r/(?:search|grep|find)\s+(?:for\s+)?["']?([\w.:-]+)/i, text) ->
        pattern = List.last(match)

        call(
          "grep",
          %{pattern: pattern},
          "I should search the project for #{pattern} and show where it appears."
        )

      String.contains?(lower, ["beam", "process", "memory", "runtime"]) ->
        call(
          "beam_stats",
          %{},
          "This is a question about the runtime. BEAM stats will answer it."
        )

      String.contains?(lower, ["list", "files", "folder", "directory", "ls"]) ->
        call(
          "list_dir",
          %{path: "."},
          "Listing the project root first gives me the lay of the land."
        )

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

  defp call(name, args, reasoning) do
    id = "demo_#{System.unique_integer([:positive])}"
    {reasoning, "", [%{id: id, name: name, arguments: Jason.encode!(args)}]}
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
