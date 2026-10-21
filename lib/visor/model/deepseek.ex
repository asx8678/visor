defmodule Visor.Model.DeepSeek do
  @moduledoc """
  Streams chat completions from DeepSeek's OpenAI-format API.

  Each setting comes from an environment variable, or from a line such as
  `DEEPSEEK_API_KEY=...` in the workspace's `.env` file, and otherwise
  from the app config:

    * `DEEPSEEK_API_KEY`, the API key, which has no default
    * `DEEPSEEK_BASE_URL`, the endpoint, such as `https://api.deepseek.com`
    * `DEEPSEEK_MODEL`, the model ID, such as `deepseek-flash`
    * `DEEPSEEK_MAX_TOKENS`, the most tokens a response may use, without
      which DeepSeek's default applies

  They are looked up on every request, so changing them doesn't need a
  restart. `mix visor.import_deepseek` copies them from pi or opencode.

  The tests send requests to a stub with `req_options: [plug: ...]` in
  the app config.
  """
  @behaviour Visor.Model

  alias Visor.Model.StreamParser

  # How often partial responses are pushed to the console.
  @emit_every_ms 80

  @no_key "No DeepSeek API key yet. To copy the one pi or opencode uses, run " <>
            "`mix visor.import_deepseek` in the project folder, or add DEEPSEEK_API_KEY " <>
            "to .env there."

  @impl true
  def info do
    %{
      provider: "DeepSeek",
      model: model(),
      endpoint: base_url(),
      max_tokens: max_tokens(),
      key: key_source()
    }
  end

  @impl true
  def stream(request, emit) do
    case api_key() do
      nil -> {:error, @no_key}
      key -> do_stream(key, request, emit)
    end
  end

  defp do_stream(key, request, emit) do
    started = now()

    result =
      Req.post(
        base_url() <> "/chat/completions",
        [
          json: body(request),
          auth: {:bearer, key},
          # Thinking at high effort can stay silent for a long time.
          receive_timeout: 600_000,
          retry: false,
          into: fn {:data, data}, {req, resp} -> {:cont, {req, handle_data(resp, data, emit)}} end
        ] ++ Keyword.get(config(), :req_options, [])
      )

    case result do
      {:ok, %Req.Response{status: 200} = resp} ->
        parser = Req.Response.get_private(resp, :parser, StreamParser.new())
        emit.(StreamParser.snapshot(parser))

        {:ok,
         %{
           message: StreamParser.message(parser),
           tool_calls: StreamParser.tool_calls(parser),
           finish_reason: parser.finish_reason,
           usage: parser.usage,
           model: parser.model,
           chunks: parser.chunks,
           ttft_ms: parser.first_token_at && parser.first_token_at - started,
           ms: now() - started
         }}

      {:ok, %Req.Response{status: status} = resp} ->
        {:error, api_error(status, Req.Response.get_private(resp, :error_body, ""))}

      {:error, exception} ->
        {:error, "The request to DeepSeek failed: " <> Exception.message(exception)}
    end
  end

  defp body(request) do
    body = %{
      model: model(),
      stream: true,
      messages: [%{role: "system", content: request.system} | request.messages],
      tools: request.tools,
      thinking: %{type: if(request.thinking, do: "enabled", else: "disabled")}
    }

    body = if request.thinking, do: Map.put(body, :reasoning_effort, request.effort), else: body
    if max = max_tokens(), do: Map.put(body, :max_tokens, max), else: body
  end

  defp handle_data(%Req.Response{status: 200} = resp, data, emit) do
    parser =
      resp
      |> Req.Response.get_private(:parser, StreamParser.new())
      |> StreamParser.feed(data)

    resp = Req.Response.put_private(resp, :parser, parser)
    now = now()

    if now - Req.Response.get_private(resp, :emitted_at, 0) >= @emit_every_ms do
      emit.(StreamParser.snapshot(parser))
      Req.Response.put_private(resp, :emitted_at, now)
    else
      resp
    end
  end

  # Error responses are JSON, not SSE; keep the body for the error message.
  defp handle_data(resp, data, _emit) do
    Req.Response.put_private(
      resp,
      :error_body,
      Req.Response.get_private(resp, :error_body, "") <> data
    )
  end

  defp api_error(status, body) do
    detail =
      case Jason.decode(body) do
        {:ok, %{"error" => %{"message" => message}}} -> message
        _ -> String.slice(body, 0, 300)
      end

    case status do
      401 -> "DeepSeek rejected the API key (401). Check DEEPSEEK_API_KEY. #{detail}"
      402 -> "The DeepSeek account has insufficient balance (402). #{detail}"
      429 -> "DeepSeek is rate limiting requests (429). Try again shortly. #{detail}"
      _ -> "DeepSeek returned HTTP #{status}. #{detail}"
    end
  end

  @doc "The API key, or nil when none is configured."
  def api_key do
    case key_lookup() do
      {_source, key} -> key
      nil -> nil
    end
  end

  defp key_source do
    case key_lookup() do
      {source, _key} -> source
      nil -> :none
    end
  end

  defp key_lookup do
    cond do
      key = present(System.get_env("DEEPSEEK_API_KEY")) -> {:env, key}
      key = dotenv("DEEPSEEK_API_KEY") -> {:dotenv, key}
      true -> nil
    end
  end

  defp setting(name, config_key, default) do
    present(System.get_env(name)) || dotenv(name) || config()[config_key] || default
  end

  defp dotenv(name) do
    case File.read(Path.join(Visor.Tools.workspace(), ".env")) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          case Regex.run(~r/^\s*(?:export\s+)?#{name}\s*=\s*(.*?)\s*$/, line) do
            [_, value] -> value |> String.trim("\"") |> String.trim("'") |> present()
            nil -> nil
          end
        end)

      {:error, _} ->
        nil
    end
  end

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value

  defp model, do: setting("DEEPSEEK_MODEL", :model, "deepseek-flash")

  # A positive whole number, or nil to leave the limit to DeepSeek.
  defp max_tokens do
    case setting("DEEPSEEK_MAX_TOKENS", :max_tokens, nil) do
      nil -> nil
      max when is_integer(max) -> max
      text -> with {max, ""} when max > 0 <- Integer.parse(text), do: max, else: (_ -> nil)
    end
  end

  defp base_url do
    "DEEPSEEK_BASE_URL"
    |> setting(:base_url, "https://api.deepseek.com")
    |> String.trim_trailing("/")
  end

  defp config, do: Application.get_env(:visor, __MODULE__, [])
  defp now, do: System.monotonic_time(:millisecond)
end
