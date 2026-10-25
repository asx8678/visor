defmodule Visor.Example.ScriptedModel do
  @moduledoc """
  The model the `loop` phase of `mix visor.example` runs the agent with:
  no network, each request answered with the next reply a check scripted
  (`play/2`). The runner names it for that phase alone (`config :visor,
  :model_provider`); Visor itself never falls back to it.

  It refuses, as DeepSeek would, a request whose messages are out of
  order (`invalid/1`), so a bug in the agent's message order fails the
  check that made the request. A request no reply was scripted for is
  refused too, and kept (`misses/0`).

  Replies:

    * `script(code, opts)`, `scripts([code], opts)`: a call of the
      `elixir` tool, or a batch of them
    * `call(arguments, opts)`: calls with the arguments as given, JSON or
      not (a list for a batch)
    * `answer(text, opts)`: the model's answer
    * `overflow(message)`: the provider's "longer than the window"
    * `hang()`: a call that never answers, until the agent stops it
    * `dynamic(fun, opts)`: the reply `fun` returns for the request, run
      in the model call's task

  Options: `for:`, text the request's first user message must hold (a
  reply meant for one of several sessions: a reply without one fits any
  request); `cost:`, the call's cost in dollars, as a gateway reports
  it; `id:`, the call's id (a list for a batch).
  """
  @behaviour Visor.Model
  use Agent

  @type reply :: %{required(:kind) => atom(), optional(atom()) => term()}

  def start_link(_opts \\ []),
    do: Agent.start_link(fn -> fresh([], nil) end, name: __MODULE__)

  @doc """
  Scripts `replies` for the requests to come, forgetting the replies,
  requests and misses before. `compact_tokens:` is the threshold `info/0`
  reports (none: Visor's own).
  """
  @spec play([reply()], keyword()) :: :ok
  def play(replies, opts \\ []),
    do: Agent.update(__MODULE__, fn _old -> fresh(replies, opts[:compact_tokens]) end)

  @doc "The requests so far, oldest first: `%{messages, tool_choice, first, reply}`."
  def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

  @doc "The replies no request has taken yet."
  def left, do: Agent.get(__MODULE__, & &1.replies)

  @doc "Why each request that got no reply got none, oldest first."
  def misses, do: Agent.get(__MODULE__, &Enum.reverse(&1.misses))

  ## Replies

  def script(code, opts \\ []), do: scripts([code], opts)

  def scripts(codes, opts \\ []),
    do: call(Enum.map(codes, &Jason.encode!(%{code: &1})), opts)

  def call(arguments, opts \\ []) do
    ids = List.wrap(opts[:id])

    calls =
      arguments
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {arguments, i} ->
        %{
          id: Enum.at(ids, i) || "s#{System.unique_integer([:positive])}",
          name: "elixir",
          arguments: arguments
        }
      end)

    reply(:calls, %{calls: calls}, opts)
  end

  def answer(text, opts \\ []), do: reply(:answer, %{content: text}, opts)
  def overflow(message, opts \\ []), do: reply(:overflow, %{message: message}, opts)
  def hang(opts \\ []), do: reply(:hang, %{}, opts)
  def dynamic(fun, opts \\ []) when is_function(fun, 1), do: reply(:dynamic, %{fun: fun}, opts)

  defp reply(kind, fields, opts),
    do: Map.merge(fields, %{kind: kind, for: opts[:for], cost: opts[:cost]})

  ## Visor.Model

  @impl true
  def info do
    compact = if Process.whereis(__MODULE__), do: Agent.get(__MODULE__, & &1.compact_tokens)

    %{
      provider: "Scripted",
      model: "scripted",
      endpoint: nil,
      max_tokens: nil,
      context_window: nil,
      compact_tokens: compact,
      key: :none
    }
  end

  @impl true
  def stream(request, emit) do
    first = first_user(request.messages)

    case invalid(request.messages) do
      nil ->
        case take(request, first) do
          nil ->
            {:error, :rejected,
             "The scripted model has no reply for this request (its first user message: " <>
               "#{inspect(String.slice(first, 0, 80))})."}

          reply ->
            respond(reply, request, emit)
        end

      problem ->
        miss(request, first, problem)
        {:error, :rejected, "DeepSeek returned HTTP 400. #{problem}"}
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

  # The first scripted reply that fits the request, taken from the script.
  defp take(request, first) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Enum.split_while(state.replies, &(not fits?(&1, first))) do
        {before, [reply | rest]} ->
          {reply,
           %{
             state
             | replies: before ++ rest,
               requests: [entry(request, first, reply.kind) | state.requests]
           }}

        {_none_fit, []} ->
          {nil,
           %{
             state
             | requests: [entry(request, first, :none) | state.requests],
               misses: ["no reply for #{inspect(String.slice(first, 0, 80))}" | state.misses]
           }}
      end
    end)
  end

  defp miss(request, first, why) do
    Agent.update(__MODULE__, fn state ->
      %{
        state
        | requests: [entry(request, first, :refused) | state.requests],
          misses: [why | state.misses]
      }
    end)
  end

  defp fits?(%{for: nil}, _first), do: true
  defp fits?(%{for: text}, first), do: String.contains?(first, text)

  defp entry(request, first, reply),
    do: %{
      messages: request.messages,
      tool_choice: Map.get(request, :tool_choice),
      first: first,
      reply: reply
    }

  defp respond(%{kind: :dynamic, fun: fun}, request, emit),
    do: respond(fun.(request), request, emit)

  defp respond(%{kind: :hang}, _request, _emit), do: Process.sleep(:infinity)

  defp respond(%{kind: :overflow, message: message}, _request, _emit),
    do: {:error, :context_overflow, message}

  defp respond(%{kind: kind} = reply, _request, emit) when kind in [:answer, :calls] do
    started = System.monotonic_time(:millisecond)
    content = Map.get(reply, :content, "")
    calls = Map.get(reply, :calls, [])
    emit.(%{reasoning: "Scripted.", content: content, tool_calls: calls, chunks: 1})
    message = %{"role" => "assistant", "content" => content, "reasoning_content" => "Scripted."}

    message =
      if calls == [],
        do: message,
        else:
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

    {:ok,
     %{
       message: message,
       tool_calls: calls,
       finish_reason: if(calls == [], do: "stop", else: "tool_calls"),
       # Only what a check set: a reported prompt size would recalibrate
       # the agent's estimates, and its compaction with them.
       usage: if(reply.cost, do: %{"completion_tokens" => 1, "cost" => reply.cost}),
       model: "scripted",
       chunks: 1,
       ttft_ms: 0,
       ms: System.monotonic_time(:millisecond) - started
     }}
  end

  defp first_user(messages) do
    case Enum.find(messages, &(&1["role"] == "user")) do
      %{"content" => content} -> Visor.Content.text(content)
      nil -> ""
    end
  end

  defp fresh(replies, compact_tokens),
    do: %{replies: replies, requests: [], misses: [], compact_tokens: compact_tokens}
end
