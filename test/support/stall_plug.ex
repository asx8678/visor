defmodule Visor.StallPlug do
  @moduledoc """
  A chat completions endpoint for the stall tests, served by a real
  Bandit server, since a stall is a socket that goes quiet. Each request
  takes the next of `behaviours`: `:silent` sends headers and then
  nothing, `:partial` sends one delta and then nothing, `:overloaded`
  ends at once for want of resources, as DeepSeek can, `:answer` sends a
  whole reply.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{counter: counter, behaviours: behaviours}) do
    attempt = :atomics.add_get(counter, 1, 1)

    case Enum.at(behaviours, attempt - 1, :answer) do
      :silent ->
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        hang(conn)

      :partial ->
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        {:ok, conn} = chunk(conn, event(%{content: "Half"}))
        hang(conn)

      :overloaded ->
        body = event(%{}, "insufficient_system_resource") <> "data: [DONE]\n\n"
        conn |> put_resp_content_type("text/event-stream") |> send_resp(200, body)

      :answer ->
        body = event(%{content: "ready"}) <> event(%{}, "stop") <> "data: [DONE]\n\n"
        conn |> put_resp_content_type("text/event-stream") |> send_resp(200, body)
    end
  end

  # Quiet until the client gives up and closes.
  defp hang(conn) do
    Process.sleep(500)
    conn
  end

  defp event(delta, finish \\ nil) do
    choice = %{index: 0, delta: delta, finish_reason: finish}
    "data: " <> Jason.encode!(%{model: "stall-test", choices: [choice]}) <> "\n\n"
  end
end
