defmodule Visor.Example.StatusPlug do
  @moduledoc """
  A stand-in for DeepSeek's endpoint in `mix visor.example`: it answers
  every request with an error, the status the path's first segment names
  and DeepSeek's kind of body, so the client's reading of each can be
  checked without the network. `/400-window/...` is a 400 that names the
  context window.
  """
  @behaviour Plug

  import Plug.Conn

  @messages %{
    "400" => "Invalid tool_calls: each must have a function name.",
    "400-window" => "This model's maximum context length is 131072 tokens.",
    "401" => "Authentication Fails, Your api key is invalid.",
    "413" => "Request Entity Too Large",
    "422" => "Failed to deserialize the JSON body."
  }

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case conn.path_info do
      [kind | _rest] when is_map_key(@messages, kind) ->
        status = kind |> String.split("-") |> hd() |> String.to_integer()
        body = Jason.encode!(%{error: %{message: @messages[kind], type: "invalid_request_error"}})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, body)

      _other ->
        send_resp(conn, 404, "")
    end
  end
end
