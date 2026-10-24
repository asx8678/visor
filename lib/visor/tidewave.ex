defmodule Visor.Tidewave do
  @moduledoc """
  A client for the Tidewave endpoint of the project's running Phoenix
  app (`plug Tidewave` in its endpoint, in dev), for `V.tidewave/2`.
  Tidewave runs the app's own tools there: `project_eval` evaluates code
  in the app, `get_logs`, `execute_sql_query`, `get_docs`,
  `get_source_location`. The code runs in the app, never in Visor's VM,
  so Visor's sandbox stands.

  The endpoint is `VISOR_TIDEWAVE_URL`, or `http://localhost:4000/tidewave/mcp`
  (`config :visor, :tidewave_url` in the tests); a tool call is one
  JSON-RPC request, as Tidewave's own MCP clients send.
  """

  @default "http://localhost:4000/tidewave/mcp"

  @doc "The app's Tidewave tools: `[%{name, description}]`."
  def tools do
    with {:ok, %{"tools" => tools}} <- request("tools/list", %{}, 10_000) do
      {:ok,
       for(
         %{"name" => name} = tool <- tools,
         do: %{name: name, description: first_line(tool["description"])}
       )}
    end
  end

  @doc "Calls tool `name` with `arguments`: `{:ok, text}` or `{:error, message}`."
  def call(name, arguments, timeout_ms) do
    case request("tools/call", %{name: name, arguments: arguments}, timeout_ms) do
      {:ok, %{"isError" => true} = result} ->
        {:error, "Tidewave's #{name} failed: " <> text(result)}

      {:ok, result} ->
        {:ok, text(result)}

      error ->
        error
    end
  end

  defp request(method, params, timeout_ms) do
    url = url()

    body = %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: method,
      params: params
    }

    case Req.post(url, json: body, receive_timeout: timeout_ms, retry: false) do
      {:ok, %Req.Response{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %Req.Response{status: 200, body: %{"error" => %{"message" => message}}}} ->
        {:error, "Tidewave said: " <> message}

      {:ok, %Req.Response{status: status}} ->
        {:error,
         "#{url} answered #{status}: is it a Phoenix app with plug Tidewave? Set " <>
           "VISOR_TIDEWAVE_URL to your app's /tidewave/mcp."}

      {:error, exception} ->
        {:error,
         "No Tidewave at #{url} (#{Exception.message(exception)}): is the app running? " <>
           "Set VISOR_TIDEWAVE_URL to its /tidewave/mcp."}
    end
  end

  defp url do
    Application.get_env(:visor, :tidewave_url) || System.get_env("VISOR_TIDEWAVE_URL") || @default
  end

  defp text(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"type" => "text", "text" => text} -> text
      other -> Jason.encode!(other)
    end)
  end

  defp text(result), do: Jason.encode!(result)

  defp first_line(nil), do: ""
  defp first_line(text), do: text |> String.trim() |> String.split("\n", parts: 2) |> hd()
end
