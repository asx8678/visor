defmodule Visor.Model.StreamParserTest do
  use ExUnit.Case, async: true

  alias Visor.Model.StreamParser

  defp sse(chunks), do: Enum.map_join(chunks, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))

  defp delta(delta, extra \\ %{}),
    do: Map.merge(%{"choices" => [%{"index" => 0, "delta" => delta}]}, extra)

  test "joins reasoning and content split across network reads" do
    body =
      sse([
        delta(%{"reasoning_content" => "Think"}),
        delta(%{"reasoning_content" => "ing."}),
        delta(%{"content" => "Hello"}),
        delta(%{"content" => " there"})
      ]) <> "data: [DONE]\n\n"

    # Cut the body inside the second line to check that partial lines are buffered.
    [first_line | _] = String.split(body, "\n\n")
    {a, b} = String.split_at(body, byte_size(first_line) + 12)
    parser = StreamParser.new() |> StreamParser.feed(a, 10) |> StreamParser.feed(b, 20)

    assert parser.done?
    assert parser.first_token_at == 10

    assert %{reasoning: "Thinking.", content: "Hello there", tool_calls: []} =
             StreamParser.snapshot(parser)

    assert StreamParser.message(parser) == %{
             "role" => "assistant",
             "content" => "Hello there",
             "reasoning_content" => "Thinking."
           }
  end

  test "merges tool call fragments by index and keeps finish reason and usage" do
    usage = %{"prompt_tokens" => 12, "completion_tokens" => 7}

    body =
      sse([
        delta(%{
          "tool_calls" => [
            %{
              "index" => 0,
              "id" => "call_a",
              "type" => "function",
              "function" => %{"name" => "read_file", "arguments" => ""}
            }
          ]
        }),
        delta(%{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "{\"path\":"}}]}),
        delta(%{
          "tool_calls" => [
            %{
              "index" => 1,
              "id" => "call_b",
              "type" => "function",
              "function" => %{"name" => "beam_stats", "arguments" => "{}"}
            }
          ]
        }),
        delta(%{
          "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "\"mix.exs\"}"}}]
        }),
        %{
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}],
          "usage" => usage
        }
      ])

    parser = StreamParser.feed(StreamParser.new(), body)

    assert parser.finish_reason == "tool_calls"
    assert parser.usage == usage

    assert StreamParser.tool_calls(parser) == [
             %{id: "call_a", name: "read_file", arguments: ~s({"path":"mix.exs"})},
             %{id: "call_b", name: "beam_stats", arguments: "{}"}
           ]

    assert %{"tool_calls" => [%{"id" => "call_a", "type" => "function"}, %{"id" => "call_b"}]} =
             StreamParser.message(parser)
  end

  test "ignores comments and blank keep-alive lines" do
    parser =
      StreamParser.feed(
        StreamParser.new(),
        ": keep-alive\n\n" <> sse([delta(%{"content" => "ok"})])
      )

    assert StreamParser.snapshot(parser).content == "ok"
  end
end
