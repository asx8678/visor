defmodule Visor.Model.DeepSeekTest do
  use ExUnit.Case, async: false

  alias Visor.Model.DeepSeek

  @moduletag :tmp_dir
  @names ~w(DEEPSEEK_API_KEY DEEPSEEK_BASE_URL DEEPSEEK_MODEL DEEPSEEK_MAX_TOKENS
             DEEPSEEK_CONTEXT_WINDOW)

  setup %{tmp_dir: tmp_dir} do
    workspace = Application.get_env(:visor, :workspace)
    config = Application.get_env(:visor, DeepSeek, [])
    Application.put_env(:visor, :workspace, tmp_dir)

    Application.put_env(
      :visor,
      DeepSeek,
      Keyword.put(config, :req_options, plug: {Req.Test, DeepSeek})
    )

    # Settings in this shell's environment would win over .env.
    saved = for name <- @names, do: {name, System.get_env(name)}
    Enum.each(@names, &System.delete_env/1)

    on_exit(fn ->
      Application.put_env(:visor, :workspace, workspace)
      Application.put_env(:visor, DeepSeek, config)

      for {name, value} <- saved do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    :ok
  end

  defp sse(chunks),
    do:
      Enum.map_join(chunks, "", &("data: " <> Jason.encode!(&1) <> "\n\n")) <> "data: [DONE]\n\n"

  test "sends the .env settings with each request and streams the reply back", %{tmp_dir: dir} do
    File.write!(Path.join(dir, ".env"), """
    DEEPSEEK_API_KEY=sk-test
    DEEPSEEK_BASE_URL=https://gateway.test/v1/
    DEEPSEEK_MODEL=deepseek-v4.1-flash
    DEEPSEEK_MAX_TOKENS=128000
    DEEPSEEK_CONTEXT_WINDOW=1048000
    """)

    Req.Test.stub(DeepSeek, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      auth = Plug.Conn.get_req_header(conn, "authorization")
      send(self(), {:request, conn.host, conn.request_path, auth, Jason.decode!(body)})

      reply =
        sse([
          %{"choices" => [%{"index" => 0, "delta" => %{"content" => "ready"}}]},
          %{
            "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
            # Usage the way OpenAI-format gateways report it.
            "usage" => %{
              "prompt_tokens" => 1209,
              "completion_tokens" => 2,
              "prompt_tokens_details" => %{"cached_tokens" => 1024}
            }
          }
        ])

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, reply)
    end)

    request = %{
      system: "Be brief.",
      messages: [%{role: "user", content: "Reply with one word: ready"}],
      tools: [],
      effort: "high",
      thinking: true
    }

    assert {:ok, %{message: %{"content" => "ready"}, finish_reason: "stop", usage: usage}} =
             DeepSeek.stream(request, fn _snapshot -> :ok end)

    assert %{"prompt_cache_hit_tokens" => 1024, "prompt_cache_miss_tokens" => 185} = usage
    assert %{max_tokens: 128_000, context_window: 1_048_000} = DeepSeek.info()

    assert_received {:request, "gateway.test", "/v1/chat/completions", ["Bearer sk-test"], body}

    assert %{
             "model" => "deepseek-v4.1-flash",
             "stream" => true,
             "max_tokens" => 128_000,
             "thinking" => %{"type" => "enabled"},
             "reasoning_effort" => "high",
             "messages" => [%{"role" => "system", "content" => "Be brief."} | _]
           } = body

    # Without a limit, DeepSeek's default applies.
    File.write!(Path.join(dir, ".env"), "DEEPSEEK_API_KEY=sk-test\nDEEPSEEK_MAX_TOKENS=lots\n")
    assert {:ok, _result} = DeepSeek.stream(%{request | thinking: false}, fn _ -> :ok end)
    assert_received {:request, "api.deepseek.com", _path, _auth, body}
    refute Map.has_key?(body, "max_tokens")
    refute Map.has_key?(body, "reasoning_effort")
    assert DeepSeek.info().max_tokens == nil
  end
end
