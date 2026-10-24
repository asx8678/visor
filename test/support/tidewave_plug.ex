defmodule Visor.TidewavePlug do
  @moduledoc """
  A Tidewave MCP endpoint for the tests, answering tools/list and
  tools/call as Tidewave's handler does: `project_eval` echoes the code
  it got, and any other tool is an error result.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, body, conn} = read_body(conn)
    %{"id" => id, "method" => method} = message = Jason.decode!(body)

    result =
      case {method, message["params"]} do
        {"tools/list", _params} ->
          %{
            tools: [
              %{
                name: "project_eval",
                description: "Evaluates Elixir code in the project.\n\nMore."
              },
              %{name: "get_logs", description: "Returns all log output."}
            ]
          }

        {"tools/call", %{"name" => "project_eval", "arguments" => %{"code" => code}}} ->
          %{content: [%{type: "text", text: "evaluated: " <> code}], isError: false}

        {"tools/call", %{"name" => name}} ->
          %{content: [%{type: "text", text: "Unknown tool #{name}"}], isError: true}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{jsonrpc: "2.0", id: id, result: result}))
  end
end
