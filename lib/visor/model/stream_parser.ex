defmodule Visor.Model.StreamParser do
  @moduledoc """
  Accumulates an OpenAI-format chat completion SSE stream into one
  assistant message.

  Network chunks don't line up with SSE lines, so incomplete lines are
  buffered until the rest arrives.
  """

  defstruct buffer: "",
            reasoning: "",
            content: "",
            tool_calls: %{},
            finish_reason: nil,
            usage: nil,
            model: nil,
            chunks: 0,
            done?: false,
            first_token_at: nil

  def new, do: %__MODULE__{}

  @doc "Feeds raw bytes from the response body."
  def feed(%__MODULE__{} = parser, data, now \\ System.monotonic_time(:millisecond)) do
    parts = String.split(parser.buffer <> data, "\n")
    {lines, [rest]} = Enum.split(parts, -1)
    Enum.reduce(lines, %{parser | buffer: rest}, &handle_line(&2, &1, now))
  end

  @doc "The partial response so far, for display."
  def snapshot(%__MODULE__{} = parser) do
    %{
      reasoning: parser.reasoning,
      content: parser.content,
      tool_calls: tool_calls(parser),
      chunks: parser.chunks
    }
  end

  @doc "Tool calls in the order the model made them."
  def tool_calls(%__MODULE__{} = parser) do
    parser.tool_calls
    |> Enum.sort_by(fn {index, _} -> index end)
    |> Enum.map(fn {index, call} ->
      %{id: call.id || "call_#{index}", name: call.name, arguments: call.arguments}
    end)
  end

  @doc """
  The assistant message to append to the conversation. DeepSeek requires
  `reasoning_content` to be sent back on every assistant message when the
  request has tools, so it is always kept.
  """
  def message(%__MODULE__{} = parser) do
    message = %{
      "role" => "assistant",
      "content" => parser.content,
      "reasoning_content" => parser.reasoning
    }

    case tool_calls(parser) do
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
  end

  defp handle_line(parser, line, now) do
    case String.trim_trailing(line, "\r") do
      "data:" <> payload ->
        case String.trim(payload) do
          "[DONE]" ->
            %{parser | done?: true}

          json ->
            case Jason.decode(json) do
              {:ok, chunk} -> apply_chunk(parser, chunk, now)
              {:error, _} -> parser
            end
        end

      # Blank event separators, ": keep-alive" comments and other fields.
      _ ->
        parser
    end
  end

  defp apply_chunk(parser, chunk, now) do
    parser = %{
      parser
      | chunks: parser.chunks + 1,
        model: parser.model || chunk["model"],
        usage: chunk["usage"] || parser.usage
    }

    Enum.reduce(chunk["choices"] || [], parser, fn choice, parser ->
      delta = choice["delta"] || %{}

      parser
      |> append(:reasoning, delta["reasoning_content"], now)
      |> append(:content, delta["content"], now)
      |> merge_tool_calls(delta["tool_calls"], now)
      |> Map.update!(:finish_reason, &(choice["finish_reason"] || &1))
    end)
  end

  defp append(parser, _key, text, _now) when text in [nil, ""], do: parser

  defp append(parser, key, text, now) do
    parser
    |> Map.update!(key, &(&1 <> text))
    |> first_token(now)
  end

  # The first delta for a call carries its id and name; later deltas carry
  # more of the arguments string.
  defp merge_tool_calls(parser, calls, _now) when calls in [nil, []], do: parser

  defp merge_tool_calls(parser, calls, now) do
    tool_calls =
      Enum.reduce(calls, parser.tool_calls, fn call, acc ->
        index = call["index"] || 0
        function = call["function"] || %{}
        current = Map.get(acc, index, %{id: nil, name: "", arguments: ""})

        Map.put(acc, index, %{
          id: call["id"] || current.id,
          name: current.name <> (function["name"] || ""),
          arguments: current.arguments <> (function["arguments"] || "")
        })
      end)

    first_token(%{parser | tool_calls: tool_calls}, now)
  end

  defp first_token(parser, now), do: %{parser | first_token_at: parser.first_token_at || now}
end
