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
    * `DEEPSEEK_CONTEXT_WINDOW`, the most tokens a request may hold, which
      the inspector measures the conversation against
    * `DEEPSEEK_COMPACT_TOKENS`, the context size that compacts the
      conversation, without which `Visor.Limits.compact_tokens/0` applies,
      kept under the window (see `Visor.Compaction`)

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
      context_window: count("DEEPSEEK_CONTEXT_WINDOW", :context_window),
      compact_tokens: count("DEEPSEEK_COMPACT_TOKENS", :compact_tokens),
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

  # A response that sends nothing for `stream_idle_ms` has stalled. One
  # that stalls before any of the reply came is sent once more: a model
  # call changes nothing, so trying again is safe. One that stalls part
  # way through ends the call.
  defp do_stream(key, request, emit, attempt \\ 1) do
    url = base_url() <> "/chat/completions"
    body = body(request)
    idle = Keyword.get(config(), :stream_idle_ms, Visor.Limits.stream_idle_ms())
    # Before sending, so a request that hangs or is rejected is on record.
    emit.({:request, %{url: url, body: body}})
    started = now()
    Process.delete(:visor_stream_data)

    result =
      Req.post(
        url,
        [
          json: body,
          auth: {:bearer, key},
          # Between any two pieces of the response, keep-alives included.
          receive_timeout: idle,
          retry: false,
          into: fn {:data, data}, {req, resp} -> {:cont, {req, handle_data(resp, data, emit)}} end
        ] ++ Keyword.get(config(), :req_options, [])
      )

    emit.({:response, response_info(result)})
    replied? = Process.get(:visor_stream_data, false)

    case result do
      {:error, %Req.TransportError{reason: :timeout}} when not replied? and attempt == 1 ->
        do_stream(key, request, emit, 2)

      {:error, %Req.TransportError{reason: :timeout}} ->
        seconds = if rem(idle, 1000) == 0, do: div(idle, 1000), else: idle / 1000

        {:error,
         if(replied?,
           do: "DeepSeek stopped sending its reply: nothing came for #{seconds} s.",
           else: "DeepSeek sent nothing for #{seconds} s, twice, so the call was given up."
         )}

      result ->
        handle_result(result, started, emit)
    end
  end

  defp handle_result(result, started, emit) do
    case result do
      {:ok, %Req.Response{status: 200} = resp} ->
        parser = Req.Response.get_private(resp, :parser, StreamParser.new())
        emit.(StreamParser.snapshot(parser))

        {:ok,
         %{
           message: StreamParser.message(parser),
           tool_calls: StreamParser.tool_calls(parser),
           finish_reason: parser.finish_reason,
           usage: cache_fields(parser.usage),
           model: parser.model,
           chunks: parser.chunks,
           ttft_ms: parser.first_token_at && parser.first_token_at - started,
           ms: now() - started
         }}

      {:ok, %Req.Response{status: status} = resp} ->
        message = api_error(status, Req.Response.get_private(resp, :error_body, ""))

        if overflow?(status, message),
          do: {:error, :context_overflow, message},
          else: {:error, message}

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
      tool_choice: Map.get(request, :tool_choice, "auto"),
      thinking: %{type: if(request.thinking, do: "enabled", else: "disabled")}
    }

    body = if request.thinking, do: Map.put(body, :reasoning_effort, request.effort), else: body
    if max = max_tokens(), do: Map.put(body, :max_tokens, max), else: body
  end

  defp handle_data(%Req.Response{status: 200} = resp, data, emit) do
    if String.contains?(data, "data:"), do: Process.put(:visor_stream_data, true)

    parser =
      resp
      |> Req.Response.get_private(:parser, StreamParser.new())
      |> StreamParser.feed(data)

    resp = Req.Response.put_private(resp, :parser, parser)
    now = now()
    # No default of 0: monotonic time may be negative.
    last = Req.Response.get_private(resp, :emitted_at)

    if last == nil or now - last >= @emit_every_ms do
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

  # What came back, for the session log. The key travels in a request
  # header, which is never part of it.
  defp response_info({:ok, %Req.Response{status: 200} = resp}),
    do: %{status: 200, headers: resp.headers}

  defp response_info({:ok, %Req.Response{} = resp}) do
    %{
      status: resp.status,
      headers: resp.headers,
      body: Req.Response.get_private(resp, :error_body, "")
    }
  end

  defp response_info({:error, exception}), do: %{error: Exception.message(exception)}

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

  # A request the API rejected for holding more tokens than the model's
  # window, such as "This model's maximum context length is 131072 tokens".
  defp overflow?(status, message) do
    status in [400, 413] and
      message =~ ~r/context (length|window)|maximum.{0,40}tokens|too many tokens/i
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
    case File.read(Path.join(Visor.Workspace.root(), ".env")) do
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

  # Without a limit, DeepSeek's default applies.
  defp max_tokens, do: count("DEEPSEEK_MAX_TOKENS", :max_tokens)

  # A positive whole number, or nil when unset or unreadable.
  defp count(name, config_key) do
    case setting(name, config_key, nil) do
      nil -> nil
      n when is_integer(n) -> n
      text -> with {n, ""} when n > 0 <- Integer.parse(text), do: n, else: (_ -> nil)
    end
  end

  # Gateways in OpenAI's format count cached prompt tokens under
  # prompt_tokens_details; the agent and the inspector read DeepSeek's names.
  defp cache_fields(%{"prompt_cache_hit_tokens" => _} = usage), do: usage

  defp cache_fields(%{"prompt_tokens" => prompt, "prompt_tokens_details" => details} = usage)
       when is_integer(prompt) and is_map(details) do
    case details["cached_tokens"] do
      hit when is_integer(hit) ->
        Map.merge(usage, %{
          "prompt_cache_hit_tokens" => hit,
          "prompt_cache_miss_tokens" => prompt - hit
        })

      _ ->
        usage
    end
  end

  defp cache_fields(usage), do: usage

  defp base_url do
    "DEEPSEEK_BASE_URL"
    |> setting(:base_url, "https://api.deepseek.com")
    |> String.trim_trailing("/")
  end

  defp config, do: Application.get_env(:visor, __MODULE__, [])
  defp now, do: System.monotonic_time(:millisecond)
end
