defmodule Visor.SessionLog.Reader do
  @moduledoc """
  Reads session logs back (`Visor.SessionLog`), for `mix visor.log` and
  for resuming a session from its log (`/resume`).
  """

  @doc "A log's lines, decoded; a line that isn't JSON comes back as `unreadable`."
  def read(file) do
    file
    |> File.stream!()
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, event} -> [event]
        {:error, _} -> [%{"event" => "unreadable", "line" => line}]
      end
    end)
  end

  @doc "The log of session `id` in `dir`, or nil."
  def find(dir, id) do
    dir |> Path.join("*-#{id}.jsonl") |> Path.wildcard() |> List.last()
  end

  @doc """
  The request of model call `turn` put back together, as it was sent:
  `{:ok, body}` or `{:error, message}`. Its own line has the messages the
  request before it didn't, and the tools when they changed. With
  `:last`, the last request in the log.
  """
  def request(events, turn) do
    requests = for %{"event" => "request"} = event <- events, do: event

    # After an agent crash, turns count from 1 again; the latest wins.
    found =
      case turn do
        :last -> if requests != [], do: 0
        turn -> Enum.find_index(Enum.reverse(requests), &(&1["turn"] == turn))
      end

    if found == nil do
      {:error, "No request for model call #{turn} in this log."}
    else
      requests = Enum.take(requests, length(requests) - found)

      messages =
        Enum.reduce(requests, [], fn r, messages ->
          Enum.take(messages, r["messages_from"]) ++ r["messages"]
        end)

      tools =
        requests |> Enum.reverse() |> Enum.find_value(&if(is_list(&1["tools"]), do: &1["tools"]))

      body = Map.put(List.last(requests)["params"], "messages", messages)
      {:ok, if(tools, do: Map.put(body, "tools", tools), else: body)}
    end
  end
end
