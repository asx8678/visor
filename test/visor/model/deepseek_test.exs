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

  test "sends the reply on as it streams in, before the response ends", %{tmp_dir: dir} do
    File.write!(Path.join(dir, ".env"), "DEEPSEEK_API_KEY=sk-test\n")

    Req.Test.stub(DeepSeek, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(
        200,
        sse([
          %{
            "choices" => [
              %{"index" => 0, "delta" => %{"content" => "hi"}, "finish_reason" => "stop"}
            ]
          }
        ])
      )
    end)

    test = self()
    request = %{system: "Be brief.", messages: [], tools: [], effort: "high", thinking: false}
    assert {:ok, _result} = DeepSeek.stream(request, &send(test, {:emitted, &1}))

    # Monotonic time may be negative, which once held every snapshot back
    # until the stream was over.
    assert emitted_kinds() == [:request, :snapshot, :response, :snapshot]
  end

  defp emitted_kinds do
    receive do
      {:emitted, {kind, _wire}} -> [kind | emitted_kinds()]
      {:emitted, %{chunks: _}} -> [:snapshot | emitted_kinds()]
    after
      0 -> []
    end
  end

  test "emits the request as sent and the response, for the session log", %{tmp_dir: dir} do
    File.write!(Path.join(dir, ".env"), "DEEPSEEK_API_KEY=sk-test\n")

    Req.Test.stub(DeepSeek, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:sent, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_header("x-request-id", "r1")
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(
        200,
        sse([%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]}])
      )
    end)

    request = %{
      system: "Be brief.",
      messages: [%{"role" => "user", "content" => "hi"}],
      tools: [],
      effort: "high",
      thinking: true
    }

    test = self()
    emit = &send(test, {:emitted, &1})

    assert {:ok, _result} = DeepSeek.stream(request, emit)
    assert_received {:sent, sent}

    assert_received {:emitted,
                     {:request, %{url: "https://api.deepseek.com/chat/completions", body: body}}}

    assert body |> Jason.encode!() |> Jason.decode!() == sent
    refute inspect(body) =~ "sk-test"
    assert_received {:emitted, {:response, %{status: 200, headers: %{"x-request-id" => ["r1"]}}}}

    Req.Test.stub(DeepSeek, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, ~s|{"error":{"message":"bad request"}}|)
    end)

    assert {:error, "DeepSeek returned HTTP 400. bad request"} = DeepSeek.stream(request, emit)

    assert_received {:emitted,
                     {:response, %{status: 400, body: ~s|{"error":{"message":"bad request"}}|}}}

    # A request over the model's window is told apart, so the agent can
    # compact the conversation and try again.
    Req.Test.stub(DeepSeek, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        400,
        ~s|{"error":{"message":"This model's maximum context length is 131072 tokens. | <>
          ~s|However, you requested 140000 tokens."}}|
      )
    end)

    assert {:error, :context_overflow, "DeepSeek returned HTTP 400. This model's maximum" <> _} =
             DeepSeek.stream(request, emit)
  end

  describe "a response that goes quiet" do
    # A real server: a stall is a socket that sends nothing.
    defp serve(dir, behaviours) do
      counter = :atomics.new(1, [])
      plug = {Visor.StallPlug, %{counter: counter, behaviours: behaviours}}

      server =
        start_supervised!({Bandit, plug: plug, ip: :loopback, port: 0, startup_log: false})

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

      File.write!(Path.join(dir, ".env"), """
      DEEPSEEK_API_KEY=sk-test
      DEEPSEEK_BASE_URL=http://127.0.0.1:#{port}
      """)

      Application.put_env(:visor, DeepSeek, stream_idle_ms: 200)
      counter
    end

    @request %{system: "Be brief.", messages: [], tools: [], effort: "high", thinking: false}

    test "is sent once more when nothing of the reply came", %{tmp_dir: dir} do
      counter = serve(dir, [:silent, :answer])

      assert {:ok, %{message: %{"content" => "ready"}}} =
               DeepSeek.stream(@request, fn _ -> :ok end)

      assert :atomics.get(counter, 1) == 2
    end

    test "is given up after a second silence", %{tmp_dir: dir} do
      counter = serve(dir, [:silent, :silent])

      assert {:error, "DeepSeek sent nothing for 0.2 s, twice, so the call was given up."} =
               DeepSeek.stream(@request, fn _ -> :ok end)

      assert :atomics.get(counter, 1) == 2
    end

    test "ends the call when it stops part way through", %{tmp_dir: dir} do
      counter = serve(dir, [:partial])

      assert {:error, "DeepSeek stopped sending its reply: nothing came for 0.2 s."} =
               DeepSeek.stream(@request, fn _ -> :ok end)

      assert :atomics.get(counter, 1) == 1
    end
  end
end
